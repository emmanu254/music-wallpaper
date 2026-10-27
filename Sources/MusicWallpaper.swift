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
    private let status = NSMenuItem(title: "Esperando a Música…", action: nil, keyEquivalent: "")
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
        generation += 1
        let info = notification.userInfo ?? [:]
        let state = (info["Player State"] as? String)?.lowercased()
        if state == "paused" || state == "stopped" {
            refreshPending = false
            hideWallpaper()
            setStatus("Música está en pausa o sin reproducir")
            return
        }
        if state == "playing", let track = cachedTrack, let image = cachedImage,
           let title = info["Name"] as? String, let artist = info["Artist"] as? String,
           let album = info["Album"] as? String,
           title == track.title, artist == track.artist, album == track.album {
            if wallpaperWindows.isEmpty { showWallpaper(image) }
            lastTrackID = track.id
        } else if state == "playing" {
            hideWallpaper()
        }
        update()
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.Music" else { return }
        generation += 1
        refreshPending = false
        hideWallpaper()
        setStatus("Abre Música para comenzar")
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
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else {
            hideWallpaper()
            setStatus("Abre Música para comenzar")
            return
        }
        busy = true
        let requestGeneration = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.readCurrentTrack()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if requestGeneration != self.generation {
                    if self.refreshPending { self.refreshPending = false; self.update() }
                    return
                }
                self.refreshPending = false
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else {
                    self.hideWallpaper()
                    self.setStatus("Abre Música para comenzar")
                    return
                }
                switch result {
                case .success(let track):
                    guard let track else {
                        self.hideWallpaper()
                        self.setStatus("Música está en pausa o sin reproducir")
                        return
                    }
                    if track.id != self.lastTrackID || self.wallpaperWindows.isEmpty {
                        guard let image = NSImage(data: track.artwork), image.isValid else {
                            self.hideWallpaper()
                            self.setStatus("Esta canción no tiene portada disponible")
                            return
                        }
                        self.cachedTrack = track
                        self.cachedImage = image
                        self.showWallpaper(image)
                        self.lastTrackID = track.id
                    }
                    self.setStatus("\(track.title) — \(track.artist)")
                case .failure(let error):
                    self.hideWallpaper()
                    self.setStatus(error.localizedDescription)
                }
            }
        }
    }

    private struct Track { let id: String; let title: String; let artist: String; let album: String; let artwork: Data }
    private struct ReadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func readCurrentTrack() -> Result<Track?, ReadError> {
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
        return .success(Track(id: id, title: title, artist: artist, album: album, artwork: artwork))
    }
}
