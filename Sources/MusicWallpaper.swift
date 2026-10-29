import AppKit
import Foundation
import ServiceManagement

private final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@main
final class MusicWallpaper: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let status = NSMenuItem(title: "Esperando a Música o Spotify…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Abrir al iniciar sesión", action: nil, keyEquivalent: "")
    private var timer: Timer?
    private var lastTrackID: String?
    private var lastMessage = ""
    private var busy = false
    private var generation = 0
    private var refreshPending = false
    private var currentImage: NSImage?
    private var cachedTrack: Track?
    private var cachedImage: NSImage?
    private var preferredPlayer: Player?
    private var displayedPlayer: Player?
    private struct WindowKey: Hashable { let display: String; let space: UInt64 }
    private var wallpaperWindows: [WindowKey: NSWindow] = [:]
    private var spaceRetry: DispatchWorkItem?
    private var spaceRetryDelay: TimeInterval = 0.75

    static func main() {
        if CommandLine.arguments.contains("--configure-only") && (CommandLine.arguments.contains("--enable-login") || CommandLine.arguments.contains("--disable-login")) {
            MusicWallpaper().configureLoginItem(enable: CommandLine.arguments.contains("--enable-login"))
            return
        }
        let app = NSApplication.shared
        let delegate = MusicWallpaper()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note.house", accessibilityDescription: "Music Wallpaper")
        let menu = NSMenu()
        menu.addItem(status)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Actualizar ahora", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        loginItem.action = #selector(toggleLoginItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        if CommandLine.arguments.contains("--enable-login") {
            configureLoginItem(enable: true)
        }
        updateLoginItemMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(musicPlaybackChanged(_:)), name: Notification.Name("com.apple.Music.playerInfo"), object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(spotifyPlaybackChanged(_:)), name: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spacesChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        hideWallpaper()
    }

    @objc private func refreshNow() {
        lastTrackID = nil
        update()
    }

    private func updateLoginItemMenu() {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.title = "Abrir al iniciar sesión"
            loginItem.state = .on
        case .requiresApproval:
            loginItem.title = "Aprobar inicio en Ajustes del Sistema…"
            loginItem.state = .off
        default:
            loginItem.title = "Abrir al iniciar sesión"
            loginItem.state = .off
        }
    }

    private func configureLoginItem(enable: Bool) {
        var errorMessage: String?
        do {
            if enable && SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                try SMAppService.mainApp.register()
            } else if !enable && (SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval) {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        let result: [String: String] = [
            "status": String(SMAppService.mainApp.status.rawValue),
            "error": errorMessage ?? ""
        ]
        if let data = try? JSONEncoder().encode(result),
           let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let folder = support.appendingPathComponent("MusicWallpaper", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent("login-registration.json"), options: .atomic)
        }
    }

    @objc private func toggleLoginItem() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
            }
        } catch {
            setStatus("No se pudo cambiar el inicio: \(error.localizedDescription)")
        }
        updateLoginItemMenu()
    }

    @objc private func screensChanged() {
        reconcileWallpaper()
    }

    @objc private func spacesChanged() {
        reconcileWallpaper()
    }

    @objc private func musicPlaybackChanged(_ notification: Notification) {
        playbackChanged(notification, from: .music)
    }

    @objc private func spotifyPlaybackChanged(_ notification: Notification) {
        playbackChanged(notification, from: .spotify)
    }

    private func playbackChanged(_ notification: Notification, from player: Player) {
        generation += 1
        let info = notification.userInfo ?? [:]
        let state = (info["Player State"] as? String)?.lowercased()
        if state == "paused" || state == "stopped" {
            if displayedPlayer == player {
                hideWallpaper()
                setStatus("Buscando reproducción activa…")
            }
            if preferredPlayer == player { preferredPlayer = nil }
            update()
            return
        }
        if state == "playing" { preferredPlayer = player }
        if state == "playing", let track = cachedTrack, track.player == player, let image = cachedImage,
           let title = info["Name"] as? String, let artist = info["Artist"] as? String,
           let album = info["Album"] as? String,
           title == track.title, artist == track.artist, album == track.album {
            if wallpaperWindows.isEmpty { showWallpaper(image) }
            lastTrackID = track.id
            displayedPlayer = player
        } else if state == "playing" {
            hideWallpaper()
        }
        update()
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let player = Player.allCases.first(where: { $0.bundleID == app.bundleIdentifier }) else { return }
        generation += 1
        if displayedPlayer == player { hideWallpaper() }
        if preferredPlayer == player { preferredPlayer = nil }
        update()
    }

    private func setStatus(_ message: String) {
        guard message != lastMessage else { return }
        lastMessage = message
        status.title = message
    }

    private func hideWallpaper() {
        spaceRetry?.cancel()
        spaceRetry = nil
        spaceRetryDelay = 0.75
        wallpaperWindows.values.forEach { $0.close() }
        wallpaperWindows.removeAll()
        currentImage = nil
        lastTrackID = nil
        displayedPlayer = nil
    }

    private func showWallpaper(_ image: NSImage) {
        currentImage = image
        reconcileWallpaper()
    }

    private func reconcileWallpaper() {
        guard let image = currentImage else { return }
        let topology = DesktopSpaces.topology()
        let allIDs = topology?.flatMap(\.ids) ?? []
        var desired: [WindowKey: NSScreen] = [:]
        var needsRetry = false
        for screen in NSScreen.screens {
            guard let identifier = DesktopSpaces.identifier(for: screen) else { continue }
            let isMain = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
            let entry = topology?.first { $0.displayID.caseInsensitiveCompare(identifier) == .orderedSame || ($0.displayID == "Main" && isMain) }
            // Space zero means the private API was unavailable: retain an AppKit fallback.
            for space in entry?.ids ?? [0] { desired[WindowKey(display: identifier, space: space)] = screen }
        }
        for key in Array(wallpaperWindows.keys) where desired[key] == nil {
            wallpaperWindows.removeValue(forKey: key)?.close()
        }
        for (key, screen) in desired {
            if let window = wallpaperWindows[key] {
                if key.space != 0 && !DesktopSpaces.isExclusivelyAssigned(window: window, to: key.space) &&
                    !DesktopSpaces.assign(window: window, to: key.space, allSpaces: allIDs) {
                    wallpaperWindows.removeValue(forKey: key)?.close()
                    needsRetry = true
                    continue
                }
                window.contentView?.layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
                continue
            }
            let window = DesktopPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
            window.title = "Music Wallpaper — Desktop"
            window.isFloatingPanel = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
            window.collectionBehavior = [.canJoinAllApplications, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            if key.space == 0 { window.collectionBehavior.insert(.canJoinAllSpaces) }
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.canHide = false
            window.isMovable = false
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
            view.layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            view.layer?.contentsGravity = .resizeAspectFill
            window.contentView = view
            window.orderFrontRegardless()
            if key.space != 0 && !DesktopSpaces.assign(window: window, to: key.space, allSpaces: allIDs) {
                window.close()
                // Space membership can be transient while macOS creates a fullscreen
                // Space. Keep the windows that succeeded and retry only missing ones.
                needsRetry = true
                continue
            }
            // WindowServer can translate a window when moving it to a Space on
            // another display. Restore the target display's global coordinates.
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            wallpaperWindows[key] = window
        }
        if needsRetry { scheduleSpaceRetry() }
        else {
            spaceRetry?.cancel()
            spaceRetry = nil
            spaceRetryDelay = 0.75
        }
    }

    private func scheduleSpaceRetry() {
        guard spaceRetry == nil else { return }
        let delay = spaceRetryDelay
        spaceRetryDelay = min(delay * 2, 5)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.spaceRetry = nil
            self.reconcileWallpaper()
        }
        spaceRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func update() {
        // Reconcile newly created or removed Spaces even if playback did not change.
        reconcileWallpaper()
        guard !busy else { refreshPending = true; return }
        guard Player.allCases.contains(where: { $0.isRunning }) else {
            hideWallpaper()
            setStatus("Abre Música o Spotify para comenzar")
            return
        }
        busy = true
        let requestGeneration = generation
        let preferred = preferredPlayer
        let cached = cachedTrack
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.readCurrentTrack(preferred: preferred, cached: cached)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if requestGeneration != self.generation {
                    if self.refreshPending { self.refreshPending = false; self.update() }
                    return
                }
                self.refreshPending = false
                guard Player.allCases.contains(where: { $0.isRunning }) else {
                    self.hideWallpaper()
                    self.setStatus("Abre Música o Spotify para comenzar")
                    return
                }
                switch result {
                case .success(let track):
                    guard let track else {
                        self.hideWallpaper()
                        self.setStatus("Música y Spotify están en pausa o sin reproducir")
                        return
                    }
                    if track.id != self.lastTrackID || track.player != self.displayedPlayer || self.wallpaperWindows.isEmpty {
                        guard let image = NSImage(data: track.artwork), image.isValid else {
                            self.hideWallpaper()
                            self.setStatus("Esta canción no tiene portada disponible")
                            return
                        }
                        self.cachedTrack = track
                        self.cachedImage = image
                        self.showWallpaper(image)
                        self.lastTrackID = track.id
                        self.displayedPlayer = track.player
                    }
                    self.setStatus("\(track.title) — \(track.artist) · \(track.player.label)")
                case .failure(let error):
                    self.hideWallpaper()
                    self.setStatus(error.localizedDescription)
                }
            }
        }
    }

    private enum Player: CaseIterable {
        case music, spotify
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
        var label: String { self == .music ? "Música" : "Spotify" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }
    private struct Track { let player: Player; let id: String; let title: String; let artist: String; let album: String; let artwork: Data; var artworkURL: URL? = nil }
    private struct ReadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func readCurrentTrack(preferred: Player?, cached: Track?) -> Result<Track?, ReadError> {
        var order = Player.allCases
        if let preferred { order = [preferred] + order.filter { $0 != preferred } }
        var firstError: ReadError?
        for player in order where player.isRunning {
            switch readCurrentTrack(from: player, cached: cached) {
            case .success(let track?): return .success(track)
            case .success(nil): continue
            case .failure(let error): if firstError == nil { firstError = error }
            }
        }
        return firstError.map { .failure($0) } ?? .success(nil)
    }

    private static func readCurrentTrack(from player: Player, cached: Track?) -> Result<Track?, ReadError> {
        if player == .spotify { return readSpotifyTrack(cached: cached) }
        let source = """
        tell application "Music"
            if player state is not playing then return {"paused"}
            set t to current track
            if (count of artworks of t) is 0 then return {"no-art"}
        return {"playing", persistent ID of t, name of t, artist of t, album of t, raw data of artwork 1 of t}
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return .failure(ReadError(message: "No se pudo preparar la consulta a Música")) }
        var details: NSDictionary?
        let result = script.executeAndReturnError(&details)
        if let details {
            let number = details[NSAppleScript.errorNumber] as? Int
            if number == -1743 { return .failure(ReadError(message: "Permite acceso a Música en Privacidad y seguridad > Automatización")) }
            return .failure(ReadError(message: "No se pudo consultar Música: \(details[NSAppleScript.errorMessage] as? String ?? "error desconocido")"))
        }
        guard let state = result.atIndex(1)?.stringValue else { return .failure(ReadError(message: "Respuesta inesperada de Música")) }
        if state == "paused" { return .success(nil) }
        if state == "no-art" { return .failure(ReadError(message: "Esta canción no tiene portada disponible")) }
        guard state == "playing", let id = result.atIndex(2)?.stringValue,
              let title = result.atIndex(3)?.stringValue, let artist = result.atIndex(4)?.stringValue,
              let album = result.atIndex(5)?.stringValue,
              let artwork = result.atIndex(6)?.data, !artwork.isEmpty else {
            return .failure(ReadError(message: "Portada no disponible para esta canción"))
        }
        return .success(Track(player: .music, id: id, title: title, artist: artist, album: album, artwork: artwork))
    }

    private final class ArtworkResponse: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        func set(_ data: Data?) { lock.lock(); value = data; lock.unlock() }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func readSpotifyTrack(cached: Track?) -> Result<Track?, ReadError> {
        let source = """
        tell application "Spotify"
            if player state is not playing then return {"paused"}
            set t to current track
            return {"playing", id of t, name of t, artist of t, album of t, artwork url of t}
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return .failure(ReadError(message: "No se pudo preparar la consulta a Spotify")) }
        var details: NSDictionary?
        let result = script.executeAndReturnError(&details)
        if let details {
            if (details[NSAppleScript.errorNumber] as? Int) == -1743 {
                return .failure(ReadError(message: "Permite acceso a Spotify en Privacidad y seguridad > Automatización"))
            }
            return .failure(ReadError(message: "No se pudo consultar Spotify: \(details[NSAppleScript.errorMessage] as? String ?? "error desconocido")"))
        }
        guard let state = result.atIndex(1)?.stringValue else { return .failure(ReadError(message: "Respuesta inesperada de Spotify")) }
        if state == "paused" { return .success(nil) }
        guard state == "playing", let id = result.atIndex(2)?.stringValue,
              let title = result.atIndex(3)?.stringValue, let artist = result.atIndex(4)?.stringValue,
              let album = result.atIndex(5)?.stringValue, let urlString = result.atIndex(6)?.stringValue,
              let url = URL(string: urlString), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com") else {
            return .failure(ReadError(message: "Portada no disponible para esta canción de Spotify"))
        }
        if let cached, cached.player == .spotify, cached.id == id, cached.artworkURL == url {
            return .success(Track(player: .spotify, id: id, title: title, artist: artist, album: album, artwork: cached.artwork, artworkURL: url))
        }
        let session = URLSession(configuration: .ephemeral)
        let semaphore = DispatchSemaphore(value: 0)
        let responseData = ArtworkResponse()
        let task = session.dataTask(with: url) { data, response, _ in
            if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
               let data, data.count <= 10_000_000 { responseData.set(data) }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 8) == .timedOut { task.cancel() }
        session.invalidateAndCancel()
        guard let artwork = responseData.get(), !artwork.isEmpty else {
            return .failure(ReadError(message: "No se pudo cargar la portada de Spotify"))
        }
        return .success(Track(player: .spotify, id: id, title: title, artist: artist, album: album, artwork: artwork, artworkURL: url))
    }
}
