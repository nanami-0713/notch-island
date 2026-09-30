import AppKit

MainActor.assumeIsolated {
    // 状态机自测入口：不启动 app，跑完退出
    if CommandLine.arguments.contains("--selftest-agent") {
        exit(AgentSelfTest.run() ? 0 : 1)
    }

    // M1 设计验收入口：离屏渲染三态假数据视图后退出，不进 app 主循环
    if let flag = CommandLine.arguments.firstIndex(of: "--render-agent-preview") {
        let args = CommandLine.arguments
        let dir = args.indices.contains(flag + 1) ? args[flag + 1] : "/tmp/notch-agent-preview"
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        AgentPreviewRenderer.run(outputDir: dir)
        exit(0)
    }

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
