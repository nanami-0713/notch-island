import AppKit

MainActor.assumeIsolated {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.nanami.notchisland"
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
