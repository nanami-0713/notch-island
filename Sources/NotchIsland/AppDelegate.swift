import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let geometry = NotchLocator.best() else {
            NSApp.terminate(nil)
            return
        }
        let controller = IslandController(geometry: geometry)
        self.controller = controller
        controller.show()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "platter.filled.top.iphone", accessibilityDescription: "NotchIsland") {
                button.image = image
            } else {
                button.title = "岛"
            }
        }
        item.menu = controller.buildMenu()
        statusItem = item

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.controller?.refreshGeometry()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
