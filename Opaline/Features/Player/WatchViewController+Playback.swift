import AVFoundation
import AVKit
import UIKit

// MARK: - Playback

extension WatchViewController {
    func startPlayback() {
        playbackFacade.watchtimeTracker.timeProvider = { [weak self] in
            self?.videoPlayerView?.player?.currentTime().seconds ?? 0
        }
        playbackFacade.watchtimeTracker.durationProvider = { [weak self] in
            let duration = self?.videoPlayerView?.player?
                .currentItem?.duration ?? .indefinite
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : 0
        }
        playbackFacade.start(
            videoId: initialVideo.id,
            apiClient: client,
            cancellationToken: pageLoadToken
        )
    }

    func attachPlayer(
        item: AVPlayerItem,
        minimizeStalling: Bool = true
    ) {
        guard !pageLoadToken.isCancelled else {
            return
        }
        if let saved = savedPlayerForBackground {
            savedPlayerForBackground = nil
            attachToExistingPlayer(
                player: saved, item: item
            )
            return
        }
        resetPlaybackSurfaces()
        playerSpinner.stopAnimating()
        playerStatusLabel.isHidden = true
        PlaybackBufferPolicy.configure(item: item)
        startObservingPlayerItem(item)
        let player = AVPlayer(playerItem: item)
        PlaybackBufferPolicy.configure(
            player: player,
            waitsToMinimizeStalling: minimizeStalling
        )
        let pv = getOrCreatePlayerView()
        configureSponsorBlock(on: pv)
        playerContainer.bringSubviewToFront(pv)
        pv.attach(player: player)
        // Start as soon as the first frames are decodable instead of
        // waiting for the stall-minimizing buffer to fill.
        player.playImmediately(atRate: pv.playbackSpeed)
    }

    private func attachToExistingPlayer(
        player: AVPlayer,
        item: AVPlayerItem
    ) {
        if let old = player.currentItem {
            stopObservingPlayerItem(old)
        }
        PlaybackBufferPolicy.configure(item: item)
        startObservingPlayerItem(item)
        player.replaceCurrentItem(with: item)
        // The duration KVO binds player.currentItem — rebind after the swap.
        videoPlayerView?.rebind(player: player)
        player.play()
    }

    /// Moves the playing item onto a brand-new `AVPlayer`. The old one is
    /// unusable for PiP once it has been detached from its layer on iOS 12,
    /// and only a different player object clears that state (#28).
    func replacePlayerPreservingPlayback() {
        guard let playerView = videoPlayerView,
              let old = playerView.player,
              let item = old.currentItem
        else {
            return
        }
        let wasPlaying = old.rate > 0
        let position = old.currentTime()
        old.pause()
        stopObservingPlayerItem(item)
        old.replaceCurrentItem(with: nil)
        // Reusing the item would throw: AVFoundation does not release its
        // association with the old player synchronously.
        let freshItem = AVPlayerItem(asset: item.asset)
        PlaybackBufferPolicy.configure(item: freshItem)
        startObservingPlayerItem(freshItem)
        let fresh = AVPlayer(playerItem: freshItem)
        PlaybackBufferPolicy.configure(
            player: fresh,
            waitsToMinimizeStalling: true
        )
        fresh.seek(to: position)
        playerView.replacePlayer(fresh)
        NowPlayingService.shared.rebindPlayer(fresh)
        AppLog.player("player rebuilt to restore PiP")
        if wasPlaying {
            fresh.playImmediately(atRate: playerView.playbackSpeed)
        }
    }

    func getOrCreatePlayerView() -> VideoPlayerView {
        if let existing = videoPlayerView {
            return existing
        }
        let playerView = VideoPlayerView()
        playerView
            .translatesAutoresizingMaskIntoConstraints
            = false
        playerView.delegate = self
        playerContainer.addSubview(playerView)
        applyEdgeConstraints(playerView, to: playerContainer)
        videoPlayerView = playerView
        playerView.setCaptionTracks(
            captionTracks,
            activeLanguage: activeSubtitleLanguage
        )
        playerView.onCCTapped = { [weak self] in
            self?.showSubtitlePicker()
        }
        playerView.onNeedsFreshPlayer = { [weak self] in
            self?.replacePlayerPreservingPlayback()
        }
        // Same semantics as the Control Center transport controls.
        playerView.onPrevious = { [weak self] in
            self?.previousFromRemote()
        }
        playerView.onNext = { [weak self] in
            self?.playNextFromRemote()
        }
        updateTransportAvailability()
        return playerView
    }

    func configureSponsorBlock(
        on playerView: VideoPlayerView
    ) {
        sponsorBlock.attach(to: playerView)
        playerView.onTimeUpdate = { [weak self] time in
            if self?.pendingRecoverySeek == false {
                self?.lastPlaybackPosition = time
            }
            self?.sponsorBlock.checkTime(time)
            NowPlayingService.shared.updatePosition(time)
            self?.videoPlayerView?.updateSubtitle(at: time)
        }
        playerView.onSkipTapped = { [weak self] in
            self?.sponsorBlock.skipCurrentSegment()
        }
        if !sponsorBlock.segments.isEmpty {
            playerView.setSponsorSegments(
                sponsorBlock.segments
            )
        }
    }

    func beginNowPlayingSession(duration: Double) {
        guard let player = videoPlayerView?.player else {
            return
        }
        NowPlayingService.shared.beginSession(
            player: player,
            metadata: NowPlayingMetadata(
                title: initialVideo.title,
                channelName: initialVideo.channelName,
                duration: duration,
                artworkURL: URL(string: initialVideo.thumbnailURL)
            ),
            onNext: { [weak self] in
                self?.playNextFromRemote()
            },
            onPrevious: { [weak self] in
                self?.previousFromRemote()
            }
        )
    }

    func resetPlaybackSurfaces() {
        videoPlayerView?.player?.pause()
        if let existing =
            videoPlayerView?.player?.currentItem {
            stopObservingPlayerItem(existing)
        }
        videoPlayerView?.detach()
        NowPlayingService.shared.endSession()
    }
}
