import Foundation
import Network
import QuartzCore
import UIKit

/// A minimal HTTP/1.1 server on the loopback interface, used to hand SABR media
/// to AVPlayer.
///
/// AVPlayer will not take HLS segments from a resource loader — a custom scheme
/// there must answer with a redirect to a real URL (-12881), and SABR segments
/// have no URL of their own. Serving them over `127.0.0.1` is the adapter
/// between a protocol that pushes bytes and a player that insists on fetching
/// them.
///
/// Keeps connections alive between requests. CFNetwork reuses sockets and
/// ignores `Connection: close`, so closing after each response left the player
/// reaching for a socket that was already gone — reported as -1005, "the
/// network connection was lost". It also answers HEAD and Range, which AVPlayer
/// probes with; leaving those unanswered surfaces as a failed player item.
final class LocalMediaServer {
    /// Answers a path with a body and content type, or nil for 404. Called on
    /// the server's queue; the completion may be called later, from anywhere.
    typealias Handler = (
        _ path: String,
        _ completion: @escaping (Data?, String) -> Void
    ) -> Void

    /// Calls back at most once, whichever comes first: the listener settling
    /// or the start timeout.
    final class Reporter {
        private(set) var done = false
        private let completion: (URL?) -> Void

        init(completion: @escaping (URL?) -> Void) {
            self.completion = completion
        }

        func report(_ url: URL?) {
            guard !done else {
                return
            }
            done = true
            completion(url)
        }
    }

    /// One parsed request — everything this server acts on.
    struct Request {
        let method: String
        let path: String
        /// Start and optional end, when the client asked for a byte range.
        let range: (start: Int, end: Int?)?
    }

    private static let startTimeout: TimeInterval = 5
    /// Replaced on returning to the foreground: iOS reclaims a suspended
    /// app's listening socket without telling the listener, and every later
    /// request fails to connect (-1004).
    /// Internal for LocalMediaServer+Foreground.swift.
    var listener: NWListener
    private var foregroundObserver: NSObjectProtocol?
    /// Bumped per reopen, so a retry left over from an earlier one stops.
    var rebinds = 0
    private let handler: Handler
    let queue = DispatchQueue(label: "com.ytvlite.local-media-server")
    /// Accepted connections, so stopping the server takes them down too —
    /// cancelling the listener alone leaves them open for the rest of the
    /// session, one set per video watched.
    ///
    /// Guarded by a lock rather than the queue: `stop()` runs from `deinit`,
    /// and dispatching there captures an object that is already being torn
    /// down — a retain on a dead reference, which crashes on whichever thread
    /// happens to be running.
    private var connections: [NWConnection] = []
    private let connectionsLock = NSLock()
    /// Set by `stop()`; a rebind still on its way then starts nothing.
    private var stopped = false

    /// The port the listener settled on, once it is ready.
    private(set) var port: UInt16?

    init?(handler: @escaping Handler) {
        guard let listener = Self.makeListener(port: .any) else {
            AppLog.hls("local server: could not create listener")
            return nil
        }
        self.listener = listener
        self.handler = handler
    }

    /// Loopback only: this must never be reachable from the network.
    static func makeListener(port: NWEndpoint.Port) -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        return try? NWListener(using: parameters)
    }

    /// Starts listening and calls back with the base URL once the port is known.
    func start(completion: @escaping (URL?) -> Void) {
        let once = Reporter(completion: completion)
        listener.stateUpdateHandler = { [weak self] state in
            self?.handle(state, once: once)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.checkAfterForeground() }
        }
        // A listener that never reaches .ready would otherwise leave the caller
        // waiting forever, which reads as "quality switching does nothing"
        // rather than as a failure.
        queue.asyncAfter(deadline: .now() + Self.startTimeout) {
            guard !once.done else {
                return
            }
            AppLog.hls("local server did not start within \(Self.startTimeout)s")
            once.report(nil)
        }
    }

    private func handle(_ state: NWListener.State, once: Reporter) {
        switch state {
        case .ready:
            port = listener.port?.rawValue
            let url = listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)") }
            AppLog.hls("local server ready on \(url?.absoluteString ?? "?")")
            once.report(url)
        case .failed(let error):
            AppLog.hls("local server failed: \(error.localizedDescription)")
            once.report(nil)
        case .waiting:
            // Not worth logging: the listener passes through .waiting on its
            // way to .ready every single time. A listener that genuinely
            // cannot start is caught by the timeout below instead.
            break
        default:
            break
        }
    }

    func stop() {
        foregroundObserver.map(NotificationCenter.default.removeObserver)
        connectionsLock.lock()
        stopped = true
        let current = listener
        let live = connections
        connections.removeAll()
        connectionsLock.unlock()
        current.cancel()
        live.forEach { $0.cancel() }
    }

    /// Swaps in a rebound listener — under the lock `stop()` reads it with,
    /// since `stop()` runs off the server queue. False once stopped.
    func adopt(_ fresh: NWListener, start: () -> Void) -> Bool {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        guard !stopped else {
            return false
        }
        listener = fresh
        start()
        return true
    }

    // MARK: - Connections

    func accept(_ connection: NWConnection) {
        // Keep-alive means the player decides when a connection is done, so
        // its end has to be noticed and the socket released — otherwise they
        // pile up in CLOSE_WAIT for the whole session.
        connectionsLock.lock()
        connections.append(connection)
        connectionsLock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                connection.cancel()
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func forget(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.removeAll { $0 === connection }
        connectionsLock.unlock()
    }

    /// Reads until the end of the request head. No bodies: these are all GETs
    /// and HEADs.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8 * 1_024
        ) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                return
            }
            var buffer = buffer
            if let chunk {
                buffer.append(chunk)
            }
            if let request = Self.parseRequest(in: buffer) {
                self.respond(to: request, on: connection)
                return
            }
            // isComplete here is the peer half-closing: nothing more is
            // coming, so let the socket go instead of waiting on it.
            guard error == nil, !isComplete, buffer.count < 8 * 1_024 else {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, buffer: buffer)
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        let started = CACurrentMediaTime()
        handler(request.path) { body, contentType in
            // Only the interesting ones: a miss, or a wait long enough that
            // the player might notice it.
            let elapsed = (CACurrentMediaTime() - started) * 1_000
            if body == nil || elapsed > 1_000 {
                let label = "\(request.method) \(request.path)"
                let size = body?.count ?? -1
                AppLog.hls(String(
                    format: "serve %@ -> %d bytes in %.0f ms", label, size, elapsed
                ))
            }
            let response = Self.response(for: request, body: body, contentType: contentType)
            let body = response.body
            connection.send(
                content: response.head,
                completion: .contentProcessed { [weak self] _ in
                    guard !body.isEmpty else {
                        self?.receiveRequest(on: connection, buffer: Data())
                        return
                    }
                    connection.send(content: body, completion: .contentProcessed { _ in
                        // Stay open and wait for the next request rather than
                        // closing: the player expects to reuse this socket.
                        self?.receiveRequest(on: connection, buffer: Data())
                    })
                }
            )
        }
    }

    deinit {
        stop()
    }
}
