import Foundation
import Network

// MARK: - Returning from the background

extension LocalMediaServer {
    /// iOS reclaims a suspended app's socket without telling the listener.
    /// Probe it once the app is back and replace it only if nothing answers:
    /// a listener that kept its socket goes on serving undisturbed.
    func checkAfterForeground() {
        guard let port, let value = NWEndpoint.Port(rawValue: port) else {
            return
        }
        let probe = NWConnection(host: "127.0.0.1", port: value, using: .tcp)
        var settled = false
        let settle: (Bool) -> Void = { [weak self] alive in
            guard !settled else {
                return
            }
            settled = true
            probe.stateUpdateHandler = nil
            probe.cancel()
            if !alive {
                self?.reopen()
            }
        }
        probe.stateUpdateHandler = { state in
            switch state {
            case .ready:
                settle(true)
            case .waiting, .failed:
                settle(false)
            default:
                break
            }
        }
        probe.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1) {
            settle(false)
        }
    }

    /// Listens again on the same port, so the URLs the player holds still
    /// lead here, once the old listener has let go of it. Connections that
    /// survived are left alone.
    func reopen() {
        rebinds += 1
        let generation = rebinds
        let old = listener
        switch old.state {
        case .cancelled, .failed:
            old.cancel()
            listen(again: 0, generation: generation)
        default:
            old.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state {
                    self?.listen(again: 0, generation: generation)
                }
            }
            old.cancel()
        }
    }

    /// Binding can still fail for a moment after the cancel: try a few times.
    func listen(again attempt: Int, generation: Int) {
        guard generation == rebinds, let port, let value = NWEndpoint.Port(rawValue: port),
              let fresh = Self.makeListener(port: value), adopt(fresh) else {
            return
        }
        fresh.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                AppLog.hls("local server: listening again on :\(port)")
            case .failed(let error) where attempt < 5:
                AppLog.hls("local server: rebinding :\(port) failed (\(error)), retrying")
                fresh.cancel()
                self?.queue.asyncAfter(deadline: .now() + 0.2 * Double(attempt + 1)) {
                    self?.listen(again: attempt + 1, generation: generation)
                }
            case .failed(let error):
                AppLog.hls("local server: could not listen on :\(port) again: \(error)")
                fresh.cancel()
            default:
                break
            }
        }
        fresh.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        fresh.start(queue: queue)
    }
}
