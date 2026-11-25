import AVFoundation
import UIKit

// MARK: - Source-prepared playback

extension WatchViewController {
    /// Where a rebuilt stream should pick up.
    ///
    /// Normally the playhead — but a rebuild can land before the saved
    /// position has been seeked to (the auto-dub probe routinely does: the
    /// primary delivers in 400 ms, the item is not even ready yet), and
    /// `currentTime` is 0 then. Handing that over restarts the video from
    /// the beginning, which is exactly what the resume was avoiding. The
    /// same holds while the resume seek is still landing: the player stands
    /// at its placeholder start, and the clock holds where it is going.
    var rebuildPlayhead: CMTime? {
        guard let view = videoPlayerView, let player = view.player else {
            return nil
        }
        if view.isResumeSeeking, let held = view.heldClock {
            return CMTime(seconds: held, preferredTimescale: 1_000)
        }
        guard !didSeekToSavedPosition,
              let saved = WatchProgressStore.shared.resumeSeconds(
                  forVideoId: initialVideo.id, duration: preparedDuration
              ) else {
            return player.currentTime()
        }
        return CMTime(seconds: saved, preferredTimescale: 1_000)
    }

    /// Attaches an `AVPlayerItem` built by a `VideoSource`, retaining its
    /// resource loader (e.g. the HLS proxy) for the item's lifetime and
    /// publishing any caption tracks the source resolved.
    func attachPrepared(
        _ prepared: PreparedPlayback,
        resumeAt: CMTime? = nil
    ) {
        activeResourceLoader = prepared.resourceLoader
        preparedDuration = prepared.duration ?? preparedDuration
        // An item the source already opened at the playhead needs no seek, and
        // asking for one anyway is actively harmful: the player then works the
        // head of the stream and the given point at the same time.
        itemStartsAt = prepared.startsAt
        if let startsAt = prepared.startsAt, startsAt > 1 {
            didSeekToSavedPosition = true
        }
        if !prepared.captions.isEmpty {
            setCaptionTracks(prepared.captions)
        }
        // Read before `attachPlayer` replaces the player it belongs to: a
        // recovery or rebuild picks up where the old one stood. A player kept
        // across a background hand-over still plays the previous video.
        let ownPlayhead = savedPlayerForBackground == nil
            ? rebuildPlayhead.map(CMTimeGetSeconds) : nil
        let playhead = pendingRecoverySeek ? lastPlaybackPosition : ownPlayhead
        // After `attachPlayer` — it is what creates the player view on a
        // first load, so an earlier call would land on nothing.
        attachPlayer(item: prepared.item)
        videoPlayerView?.setAudioOnly(
            active: AudioOnlyMode.isEnabled,
            available: playbackFacade.activeVideoSource?.availableQualities
                .contains { $0.id == AudioOnlyMode.qualityID } ?? false
        )
        if let resumeAt, CMTimeGetSeconds(resumeAt) > 1 {
            pendingResumeSeek = resumeAt
        }
        // The clock reads 0:00 until the item reports a time, seconds away on
        // a slow stream; show where playback is going to start instead.
        let start = resumeAt.map(CMTimeGetSeconds)
            ?? prepared.startsAt
            ?? playhead
            ?? rebuildPlayhead.map(CMTimeGetSeconds)
        if let start, start > 1 {
            videoPlayerView?.showClock(at: start)
        }
    }

    /// Seeks a freshly attached stream back to where the user was. Called from
    /// the item's ready callback: issued any earlier the player is still
    /// loading and silently drops it.
    func applyResumeSeekIfNeeded() {
        guard let target = pendingResumeSeek else {
            return
        }
        pendingResumeSeek = nil
        let tolerance = CMTime(seconds: 1, preferredTimescale: 1_000)
        videoPlayerView?.player?.seek(
            to: target,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    /// Source-agnostic quality menu: renders `source.availableQualities` and
    /// applies the pick via `source.selectQuality`. No source-specific code.
    func showSourceQualityPicker(source: VideoSource) {
        let items = source.availableQualities.map { quality -> PlayerMenuItem in
            let isCurrent = quality == source.currentQuality
            let title = isCurrent ? "✓ \(quality.label)" : quality.label
            return PlayerMenuItem(title: title) { [weak self] in
                self?.selectSourceQuality(quality, source: source)
            }
        }
        presentPlayerMenu(
            title: "player.menu.quality".localized, items: items
        )
    }

    func selectSourceQuality(
        _ quality: VideoQuality,
        source: VideoSource
    ) {
        guard quality != source.currentQuality else {
            return
        }
        let resumeTime = rebuildPlayhead
        playerStatusLabel.text = "player.status.loading"
            .localized(with: quality.label)
        playerStatusLabel.isHidden = false
        source.selectQuality(
            quality, resumeAt: resumeTime.map(CMTimeGetSeconds)
        ) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let prepared):
                    // The old item kept playing for however long the rebuild
                    // took (1–3 s on SABR). Seeking back to where the playhead
                    // was when the menu was tapped would undo exactly that, so
                    // read it again now.
                    self?.attachPrepared(prepared, resumeAt: self?.rebuildPlayhead)
                case .failure:
                    self?.showPlaybackError(
                        "player.error.qualitySwitch".localized
                    )
                }
            }
        }
    }
}
