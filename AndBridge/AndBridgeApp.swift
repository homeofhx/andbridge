import AppKit
import SwiftUI

@main
enum AndBridgeApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = BrowserViewModel()
    private var windowController: NSWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow(nil)
        model.start()
    }

    @objc private func showMainWindow(_ sender: Any?) {
        if windowController == nil { windowController = makeMainWindowController() }
        guard let window = windowController?.window else { return }
        windowController?.showWindow(sender)
        window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func getLatestRelease(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/homeofhx/andbridge/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }

    private func makeMainWindowController() -> NSWindowController {
        let contentView = ContentView(model: model)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "AndBridge"
        window.minSize = NSSize(width: 780, height: 500)
        window.setContentSize(NSSize(width: 980, height: 640))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        return NSWindowController(window: window)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "AndBridge")
        let showFromAppMenuItem = NSMenuItem(title: "Show AndBridge Window",
                                             action: #selector(showMainWindow(_:)),
                                             keyEquivalent: "")
        showFromAppMenuItem.target = self
        appMenu.addItem(showFromAppMenuItem)
        let latestReleaseItem = NSMenuItem(title: "Get the Latest Release",
                                           action: #selector(getLatestRelease(_:)),
                                           keyEquivalent: "")
        latestReleaseItem.target = self
        appMenu.addItem(latestReleaseItem)
        let quitItem = NSMenuItem(title: "Quit!",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "\u{001B}")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let showItem = NSMenuItem(title: "Show AndBridge Window",
                                  action: #selector(showMainWindow(_:)),
                                  keyEquivalent: "0")
        showItem.target = self
        windowMenu.addItem(showItem)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    @available(macOS 12.0, *)
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

}
