import UIKit

final class VideoRouter {
    static let shared = VideoRouter()

    var watchViewControllerFactory: ((Video) -> WatchViewController)?
    /// Shorts open in their own full-screen vertical feed, not the watch screen.
    var shortsViewControllerFactory: ((Video, ShortsEntry) -> UIViewController)?
    /// Lets Core screens push a channel without importing Features.
    var channelViewControllerFactory: ((String, String) -> UIViewController)?
    /// Same idea for a playlist opened from a link.
    var playlistViewControllerFactory: ((Playlist) -> UIViewController)?
    private var panel: PlayerPanelViewController?

    /// The video currently loaded in the mini/full player, if any — lets
    /// `VideoActionMenu` seed an empty queue with the right "now playing"
    /// item instead of guessing.
    var currentVideo: Video? {
        guard let watchVC = panel?.watchVC else {
            return nil
        }
        return watchVC.watchPage?.video ?? watchVC.initialVideo
    }

    private var keyWindowMainTabBar: MainTabBarController? {
        var root = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController
        while let presented = root?.presentedViewController {
            root = presented
        }
        return (root as? RootContainerViewController)?.mainTabBar
            ?? root as? MainTabBarController
    }

    private init() {}

    /// - Parameter shorts: how the shorts feed continues past `video` —
    ///   see `ShortsEntry`.
    func open(
        video: Video,
        from presenter: UIViewController,
        shorts: ShortsEntry = .pool([])
    ) {
        if video.isShort,
           ShortsPlayerMode.selected == .vertical,
           let makeShorts = shortsViewControllerFactory {
            // The outermost one: Library's segments sit in an embedded
            // navigation controller whose view stops below the status bar,
            // and a full-screen feed pushed there leaves that strip showing
            // the screen underneath.
            presenter.visibleNavigationController?.pushViewController(
                makeShorts(video, shorts), animated: true
            )
            return
        }
        if let panel {
            // Already playing there: bring it up rather than start it over.
            if !panel.watchVC.isAlreadyPlaying(video) {
                panel.watchVC.loadVideo(video)
            }
            panel.expand(animated: true)
            return
        }
        guard let factory = watchViewControllerFactory else {
            assertionFailure("VideoRouter not configured")
            return
        }
        let watchVC = factory(video)
        let newPanel = PlayerPanelViewController(watchVC: watchVC)
        newPanel.onClose = { [weak self] in
            self?.panel = nil
        }
        panel = newPanel
        guard let tabBar = findTabBarController(from: presenter) else {
            self.panel = nil
            return
        }
        tabBar.installPlayerPanel(newPanel)
    }

    /// Opens a video known only by id — e.g. a `ytlite://` deep link or a
    /// tapped youtube.com link. `seconds` is the link's own timecode
    /// (`?t=87`), which outranks stored watch progress, and `isShort` sends
    /// it to the vertical feed instead of the watch screen. Presents on the
    /// currently selected tab of `MainTabBarController`; a no-op if the main
    /// UI isn't up yet.
    func openVideoId(
        _ videoId: String,
        startAt seconds: Double? = nil,
        isShort: Bool = false,
        playlistId: String? = nil
    ) {
        if let panel, !isShort,
           panel.watchVC.isAlreadyPlaying(Video(id: videoId, playlistId: playlistId)) {
            if let seconds {
                panel.watchVC.seek(toLinkTime: seconds)
            }
            panel.expand(animated: true)
            return
        }
        if let seconds {
            WatchProgressStore.shared.setLinkStart(
                seconds: seconds, forVideoId: videoId
            )
        }
        guard let tabBar = keyWindowMainTabBar,
              let presenter = tabBar.selectedViewController
        else {
            return
        }
        open(
            video: Video(id: videoId, isShort: isShort, playlistId: playlistId),
            from: presenter
        )
    }

    /// Opens a playlist known only by id — a shared `youtube.com/playlist`
    /// link. The screen fetches its own contents, so a title placeholder is
    /// all it needs to start.
    func openPlaylistId(_ playlistId: String) {
        guard let makePlaylist = playlistViewControllerFactory,
              let tabBar = keyWindowMainTabBar,
              let presenter = tabBar.selectedViewController
        else {
            return
        }
        let playlist = Playlist(
            id: playlistId,
            title: "common.playlist".localized,
            description: "",
            thumbnailURL: nil,
            itemCount: nil
        )
        presenter.visibleNavigationController?.pushViewController(
            makePlaylist(playlist), animated: true
        )
    }

    func minimize() {
        panel?.collapse(animated: true)
    }

    /// Pushes a channel screen onto the tab underneath the player and
    /// collapses the player to the mini bar — matching the official app,
    /// which never lets a pushed screen cover the expanded player.
    /// `presenter` is the fallback for callers with no player open — the
    /// action menu opens from feeds as well as from the watch screen.
    func openChannel(
        id: String,
        name: String,
        from presenter: UIViewController? = nil
    ) {
        guard let factory = channelViewControllerFactory else {
            return
        }
        let channel = factory(id, name)
        if let tabNav = panel?.owner?.selectedViewController as? UINavigationController {
            tabNav.pushViewController(channel, animated: true)
            minimize()
            return
        }
        presenter?.visibleNavigationController?
            .pushViewController(channel, animated: true)
    }

    /// Brings the full player back — used when PiP asks the app to restore
    /// its own playback UI, which AVKit expects to be on screen.
    func expandPanel() {
        panel?.expand(animated: false)
    }

    func clearCurrentWatch() {
        panel?.close()
    }

    private func findTabBarController(from vc: UIViewController) -> MainTabBarController? {
        var root = vc.view.window?.rootViewController
        while let presented = root?.presentedViewController {
            root = presented
        }
        return (root as? RootContainerViewController)?.mainTabBar
            ?? root as? MainTabBarController
            ?? vc.tabBarController as? MainTabBarController
            ?? vc.navigationController?.tabBarController as? MainTabBarController
    }
}
