import AppKit
import SwiftUI
import ServiceManagement

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Reliable static reference — avoids `NSApp.delegate as? AppDelegate` cast failures in Swift 6.
    static weak var shared: AppDelegate?

    // MARK: Shared objects (owned here, injected everywhere via EnvironmentObject)

    let settings:         AppSettings
    let libraryManager:   VideoLibraryManager
    let wallpaperManager: WallpaperManager

    override init() {
        let settings = AppSettings()
        let library  = VideoLibraryManager()
        self.settings         = settings
        self.libraryManager   = library
        self.wallpaperManager = WallpaperManager(settings: settings, library: library)
        super.init()
    }

    // MARK: Private UI refs

    private var statusItem:     NSStatusItem?
    private var popover:        NSPopover?
    private var splashWindow:   NSWindow?
    private var settingsWindow: NSWindow?
    private var monitor:        Any?   // global event monitor for click-outside

    // MARK: applicationDidFinishLaunching

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Run as a menu-bar-only agent (no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Wire dependencies
        wallpaperManager.setup()

        // Restore last-used video
        restoreLastVideo()

        // Apply launch-at-login preference
        applyLaunchAtLogin()

        // Build menu bar
        setupStatusItem()

        // Splash on first run / after update
        showSplashIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaperManager.teardown()
        libraryManager.stopWatching()
    }

    // MARK: - Status Item / Popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.image = NSImage(systemSymbolName: "play.rectangle.fill",
                               accessibilityDescription: "VideoWall")
        button.image?.isTemplate = true
        button.action  = #selector(togglePopover(_:))
        button.target  = self

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 540)
        popover.behavior    = .transient
        popover.animates    = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView()
                .environmentObject(wallpaperManager)
                .environmentObject(libraryManager)
                .environmentObject(settings)
        )
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button,
              let popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Settings Window

    @objc func openSettings() {
        // Close the popover and wait for its animation to finish before
        // activating the settings window — avoids focus-race on Tahoe.
        popover?.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.presentSettingsWindow()
        }
    }

    private func presentSettingsWindow() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(wallpaperManager)
                .environmentObject(libraryManager)
                .environmentObject(settings)

            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                styleMask:   [.titled, .closable, .miniaturizable],
                backing:     .buffered,
                defer:       true    // defer: true — Tahoe ARC fix
            )
            win.title                = "VideoWall · Settings"
            win.center()
            win.isReleasedWhenClosed = false
            win.contentViewController = NSHostingController(rootView: view)

            // Switch back to accessory when the settings window closes.
            // queue: .main → assumeIsolated is safe; avoids accessing @MainActor
            // vars (NSApp, settingsWindow) from a @Sendable closure.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object:  win,
                queue:   .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    NSApp.setActivationPolicy(.accessory)
                    self?.settingsWindow = nil
                }
            }
            settingsWindow = win
        }

        // Menu-bar (accessory) apps must temporarily become .regular to
        // receive key focus and bring a floating window to the front.
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Splash Screen

    private func showSplashIfNeeded() {
        let key = "splashShown_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        showSplash()
    }

    // Called from debug / "Replay Intro" button
    @objc func showSplash() {
        let view = SplashScreenView {
            DispatchQueue.main.async { [weak self] in
                // orderOut (hide) rather than close() to avoid autorelease double-release.
                // ARC releases the NSWindow when splashWindow = nil below.
                self?.splashWindow?.orderOut(nil)
                self?.splashWindow = nil
            }
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       true    // defer: true — never display inside init (Tahoe ARC fix)
        )
        win.isOpaque             = false
        win.backgroundColor      = .clear
        win.level                = .floating
        win.hasShadow            = true
        win.isReleasedWhenClosed = false   // ARC owns the window; prevent system double-release
        win.center()
        win.contentViewController = NSHostingController(rootView: view)
        win.orderFront(nil)                // orderFront after full configuration, not makeKeyAndOrderFront
        splashWindow = win
    }

    // MARK: - Helpers

    private func restoreLastVideo() {
        guard let id = settings.selectedVideoID,
              let video = libraryManager.videos.first(where: { $0.id == id })
        else { return }
        wallpaperManager.play(video: video)
    }

    func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if settings.launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[LaunchAtLogin] \(error)")
            }
        }
    }
}
