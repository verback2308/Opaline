import AVKit
import UIKit

// MARK: - Player Observing

extension WatchViewController {
    func startObservingPlayerItem(_ item: AVPlayerItem) {
        statusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] observed, _ in
            self?.handlePlayerItemStatusChange(observed)
        }
        addPlayerNotificationObservers(for: item)
    }

    func addPlayerNotificationObservers(
        for item: AVPlayerItem
    ) {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(playerItemDidFailToPlayToEnd(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item
        )
        nc.addObserver(
            self,
            selector: #selector(playerItemNewErrorLogEntry(_:)),
            name: .AVPlayerItemNewErrorLogEntry,
            object: item
        )
        nc.addObserver(
            self,
            selector: #selector(playerItemDidPlayToEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    func stopObservingPlayerItem(
        _ item: AVPlayerItem
    ) {
        let nc = NotificationCenter.default
        nc.removeObserver(
            self,
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item
        )
        nc.removeObserver(
            self,
            name: .AVPlayerItemNewErrorLogEntry,
            object: item
        )
        nc.removeObserver(
            self,
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
        statusObservation?.invalidate()
        statusObservation = nil
    }

    func handlePlayerItemStatusChange(
        _ item: AVPlayerItem
    ) {
        switch item.status {
        case .readyToPlay:
            logReadyToPlay(item)
        case .failed:
            logPlaybackFailure(item)
        case .unknown:
            AppLog.player("player item status unknown")
        @unknown default:
            AppLog.player(
                "player item status unexpected"
            )
        }
    }

    func logReadyToPlay(_ item: AVPlayerItem) {
        if applyRecoverySeekIfNeeded(item) {
            return
        }
        // Not an early return: a switched stream still needs its Now Playing
        // session rebound to the new player below.
        applyResumeSeekIfNeeded()
        let duration = CMTimeGetSeconds(item.duration)
        let tracks = item.tracks
            .map {
                $0.assetTrack?.mediaType.rawValue
                    ?? "?"
            }
            .joined(separator: ",")
        AppLog.player(
            "player item ready:"
                + " duration=\(duration)s"
                + " tracks=[\(tracks)]"
        )
        seekToSavedPositionIfNeeded()
        beginNowPlayingSession(duration: duration)
    }

    private func seekToSavedPositionIfNeeded() {
        guard !didSeekToSavedPosition else {
            return
        }
        didSeekToSavedPosition = true
        guard let player = videoPlayerView?.player else {
            return
        }
        let dur = CMTimeGetSeconds(
            player.currentItem?.duration ?? .zero
        )
        guard let pos = WatchProgressStore.shared.resumeSeconds(
            forVideoId: initialVideo.id, duration: dur
        ) else {
            return
        }
        // The source may already have built the stream at this position
        // (SABR opens at the playhead) — seeking to where playback already
        // stands is a no-op, so this stays unconditional.
        seekCoveringStart(player, to: pos)
        AppLog.player(
            "resumed at \(Int(pos))s of \(Int(dur))s"
        )
    }

    /// Until the seek lands the item shows its opening frame and clock; keep
    /// both covered so the video appears straight at the resume point.
    private func seekCoveringStart(_ player: AVPlayer, to pos: Double) {
        let cover = abs(CMTimeGetSeconds(player.currentTime()) - pos) > 1
        if cover {
            videoPlayerView?.beginResumeSeek(to: pos)
        }
        player.seek(
            to: CMTime(seconds: pos, preferredTimescale: 1_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            guard cover else {
                return
            }
            DispatchQueue.main.async {
                self?.videoPlayerView?.endResumeSeek()
            }
        }
    }

    func logPlaybackFailure(_ item: AVPlayerItem) {
        let nsError = item.error as NSError?
        let desc = item.error?.localizedDescription
            ?? "unknown"
        let domain = nsError?.domain ?? "nil"
        let code = nsError?.code ?? 0
        AppLog.player(
            "player item FAILED: \(desc)"
                + " domain=\(domain)"
                + " code=\(code)"
        )
        logUnderlyingError(nsError)
        if code == -12_660
            || domain == "CoreMediaErrorDomain" {
            hasSeenPlaybackError = true
            if !isRecoveringPlayback {
                AppLog.player(
                    "player failure — scheduling recovery"
                )
                recoverPlayback()
            }
        }
    }

    func logUnderlyingError(_ nsError: NSError?) {
        guard let underlying = nsError?
            .userInfo[NSUnderlyingErrorKey]
            as? NSError
        else {
            return
        }
        AppLog.player(
            "underlying error:"
                + " \(underlying.domain)"
                + " code=\(underlying.code)"
                + " \(underlying.localizedDescription)"
        )
    }

    @objc
    func playerItemDidFailToPlayToEnd(
        _ note: Notification
    ) {
        let errorKey =
            AVPlayerItemFailedToPlayToEndTimeErrorKey
        let error =
            (note.userInfo?[errorKey] as? Error)?
                .localizedDescription ?? "unknown"
        AppLog.player(
            "player item failed to end: \(error)"
        )
        hasSeenPlaybackError = true
        if !isRecoveringPlayback {
            recoverPlayback()
        }
    }

    @objc
    func playerItemNewErrorLogEntry(
        _ note: Notification
    ) {
        guard let item =
            note.object as? AVPlayerItem,
            let events = item.errorLog()?.events,
            let last = events.last
        else {
            AppLog.player(
                "player item new error log entry"
            )
            return
        }
        let domain = last.errorDomain
        let comment = last.errorComment ?? "nil"
        let uri = last.uri ?? "nil"
        AppLog.player(
            "player error log:"
                + " domain=\(domain),"
                + " code=\(last.errorStatusCode),"
                + " comment=\(comment),"
                + " uri=\(uri)"
        )
        if last.errorStatusCode == 403 {
            hasSeenPlaybackError = true
            if !isRecoveringPlayback {
                AppLog.player(
                    "403 detected — scheduling recovery"
                )
                recoverPlayback()
            }
        }
    }

    func showPlaybackError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.playerSpinner.stopAnimating()
            self?.playerStatusLabel.text =
                "player.error.withMessage".localized(with: message)
            self?.playerStatusLabel.textColor =
                .systemRed
        }
    }
}
