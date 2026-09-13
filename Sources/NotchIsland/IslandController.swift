import AppKit
import ApplicationServices
import QuartzCore
import ServiceManagement
import SwiftUI

@MainActor
final class IslandController: NSObject, NSMenuDelegate {
    /// 临时诊断：直接落盘，避免 NSLog 缓存/丢失
    nonisolated static func debugLog(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/notch_debug.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private(set) var geometry: ScreenGeometry
    private let window: IslandWindow
    private let state = IslandState()
    private let music = NowPlayingMonitor()
    private var tickTimer: Timer?
    private var globalMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var lastPasteboardCount = 0
    private var batteryCheckCounter = 0
    private var lastCharging: Bool?
    private var isHovering = false
    private let stash = StashStore()
    private let volumeWatcher = VolumeWatcher()
    private let mediaKeyTap = MediaKeyTap()
    private let lyrics = LyricsService()
    private var lyricsKey: String?
    private var mediaKeyTapRetryTick = 0
    private var brightnessNilReads = 0
    private var tickCount = 0

    /// 歌词开关（默认开）
    private var showLyrics: Bool {
        get { UserDefaults.standard.object(forKey: "showLyrics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showLyrics") }
    }
    private var lastBrightness: Double?
    private var brightnessInvalidReads = 0
    private var brightnessDisabled = false

    // 弹簧动画状态
    private var springTimer: Timer?
    private var currentW: CGFloat = 0
    private var currentH: CGFloat = 0
    private var velocityW: CGFloat = 0
    private var velocityH: CGFloat = 0
    private var targetW: CGFloat = 0
    private var targetH: CGFloat = 0
    private var lastFrameTimestamp: TimeInterval = 0

    init(geometry: ScreenGeometry) {
        let win = Self.makeWindow()
        self.geometry = geometry
        self.window = win
        super.init()
        win.controller = self

        state.notchWidth = geometry.notchWidth
        state.notchHeight = geometry.notchHeight
        state.hasNotch = geometry.hasNotch
        state.controller = self

        let container = IslandContainerView()
        container.controller = self
        let hosting = NSHostingView(rootView: IslandView(state: state))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.hostingView = hosting
        win.contentView = container

        lastPasteboardCount = NSPasteboard.general.changeCount
        state.stashed = stash.files
        music.onUpdate = { [weak self] _ in self?.refreshLayout() }
    }

    private static func makeWindow() -> IslandWindow {
        let frame = NSRect(x: 0, y: 0, width: 260, height: 40)
        let win = IslandWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .statusBar
        win.isMovable = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return win
    }

    func show() {
        Self.debugLog("show enter")
        refreshLayout()
        window.orderFrontRegardless()
        music.start()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickOnce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.collapseIfExpanded()
            }
        }

        volumeWatcher.onChange = { [weak self] volume, muted in
            Task { @MainActor [weak self] in
                self?.showVolumeHUD(volume: volume, muted: muted)
            }
        }
        volumeWatcher.start()

        // 有辅助功能权限就拦截媒体键、隐藏系统自带 HUD；没权限则每 5 秒静默重试（授权后自动生效）
        mediaKeyTap.onKey = { [weak self] key in
            self?.handleMediaKey(key) ?? false
        }
        if mediaKeyTapAutoStart {
            activateMediaKeyTap()
        }
        Self.debugLog("show exit tapRunning=\(mediaKeyTap.isRunning)")

        // 零权限兜底：用户点进任何其他 app（触发其激活）就收起
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, self.state.expanded else { return }
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.bundleIdentifier == Bundle.main.bundleIdentifier {
                    return
                }
                self.collapseIfExpanded()
            }
        }
    }

    func shutdown() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        stopSpring()
        mediaKeyTap.stop()
        music.shutdown()
        UserDefaults.standard.set(false, forKey: "mediaKeyTapActive")
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - 布局

    func refreshLayout() {
        let ext = extensionContent()
        state.extensionItem = ext
        let target = targetFrame(ext: ext)
        state.currentWidth = target.width
        animate(to: target)
    }

    /// 窗口形变用逐帧弹簧驱动：可中断、可重定目标，
    /// 且渲染宽度钳制在不小于"刘海宽 + 边距"，任何时刻都不会露出物理刘海
    private func animate(to target: NSRect) {
        let springIdle = springTimer == nil
        if springIdle, currentW != 0,
           abs(target.width - currentW) < 0.5, abs(target.height - currentH) < 0.5 {
            return
        }
        targetW = target.width
        targetH = target.height
        if currentW == 0 {
            currentW = target.width
            currentH = target.height
            applySpringFrame(final: true)
            return
        }
        startSpring()
    }

    private func startSpring() {
        guard springTimer == nil else { return }
        lastFrameTimestamp = 0
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.springTick()
            }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    private func stopSpring() {
        springTimer?.invalidate()
        springTimer = nil
    }

    private func springTick() {
        let now = Date().timeIntervalSinceReferenceDate
        springStep(dt: lastFrameTimestamp == 0 ? 1.0 / 120.0 : min(0.05, now - lastFrameTimestamp),
                   timestamp: now)
    }

    private func springStep(dt: TimeInterval, timestamp: TimeInterval) {
        lastFrameTimestamp = timestamp
        // 收起过程用更硬的过阻尼弹簧（无过冲），展开用轻微欠阻尼（有一点回弹）
        let growing = targetW >= currentW
        let stiffness: CGFloat = growing ? 190 : 260
        let damping: CGFloat = growing ? 20 : 34

        let accelW = stiffness * (targetW - currentW) - damping * velocityW
        let accelH = stiffness * (targetH - currentH) - damping * velocityH
        let dtc = CGFloat(dt)
        velocityW += accelW * dtc
        velocityH += accelH * dtc
        currentW += velocityW * dtc
        currentH += velocityH * dtc

        let settled = abs(targetW - currentW) < 0.5 && abs(velocityW) < 2
            && abs(targetH - currentH) < 0.5 && abs(velocityH) < 2
        if settled {
            currentW = targetW
            currentH = targetH
            velocityW = 0
            velocityH = 0
            applySpringFrame(final: true)
            stopSpring()
        } else {
            applySpringFrame(final: false)
        }
    }

    private func applySpringFrame(final: Bool) {
        let minCovered = geometry.notchWidth + 16
        let width = max(minCovered, currentW)
        let height = max(geometry.notchHeight, currentH)
        let screen = geometry.screen
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        if final {
            window.setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: false)
        }
    }

    private func targetFrame(ext: IslandExtension?) -> NSRect {
        let screen = geometry.screen
        if state.expanded {
            let width: CGFloat = 340
            let topSafe = geometry.notchHeight + 12
            var content: CGFloat = 0
            var sections = 0
            if let activity = state.activity, activity.until > Date() {
                content += 22
                sections += 1
            }
            if state.timerDeadline != nil {
                content += 36
                sections += 1
            }
            if state.music != nil {
                content += 140
                sections += 1
            }
            if showLyrics && state.music != nil && state.lyricLine != nil {
                content += 24
            }
            if !state.stashed.isEmpty {
                content += 26 + 8 + CGFloat(min(4, state.stashed.count)) * 26
                if state.stashed.count > 4 { content += 14 }
                sections += 1
            }
            if sections == 0 { content = 88 }
            content += CGFloat(max(0, sections - 1)) * 12
            let height = max(geometry.hasNotch ? 196 : 224, min(topSafe + content + 16, 400))
            return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        }

        // 非对称贴边布局（alcove 同款）：窗口左缘 = 刘海左 - 图标翼展，右缘 = 刘海右 + 文本翼展，
        // 图标/文字各自紧贴刘海两侧 10pt，任何内容都不会钻进刘海底下
        // 非对称贴边布局（alcove 同款），三种收起模式：
        // 文本（计时/动态）：左图标、右文字；音乐：左封面 22、右声纹；空闲：纯刘海 + 24pt 边距
        let sideGap: CGFloat = 8
        let edgeMargin: CGFloat = 12
        let notchLeft = screen.frame.midX - geometry.notchWidth / 2

        let leftExtent: CGFloat
        let rightExtent: CGFloat
        if let ext {
            leftExtent = sideGap + 14 + edgeMargin
            rightExtent = sideGap + ext.textWidth + edgeMargin
        } else if state.music != nil {
            leftExtent = sideGap + 22 + 8
            rightExtent = sideGap + 26 + 10
        } else {
            leftExtent = edgeMargin
            rightExtent = edgeMargin
        }
        let peek: CGFloat = isHovering ? 14 : 0
        let width = geometry.notchWidth + leftExtent + rightExtent + peek
        let height = geometry.notchHeight
        return NSRect(
            x: notchLeft - leftExtent - peek / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// 展开态优先级：计时 > 临时动态 > 暂存角标 > 音乐
    private func extensionContent() -> IslandExtension? {
        if state.expanded { return nil }
        if let deadline = state.timerDeadline {
            let text = Self.formatCountdown(max(0, deadline.timeIntervalSinceNow))
            return IslandExtension(symbol: "timer", text: text, textWidth: Self.textWidth(text))
        }
        if let activity = state.activity, activity.until > Date() {
            return IslandExtension(symbol: activity.symbol, text: activity.text, textWidth: Self.textWidth(activity.text))
        }
        if !state.stashed.isEmpty {
            let text = "\(state.stashed.count) 个文件"
            return IslandExtension(symbol: "tray.full.fill", text: text, textWidth: Self.textWidth(text))
        }
        // 音乐收起态改用「封面 + 声纹」视图，不再用文字
        return nil
    }

    private static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    static func formatCountdown(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - 周期任务

    private func tickOnce() {
        tickCount += 1
        if tickCount <= 3 {
            Self.debugLog("tick #\(tickCount)")
        }
        if let activity = state.activity, activity.until <= Date() {
            state.activity = nil
            refreshLayout()
        }

        checkClipboard()
        checkBrightness()

        // 未拿到辅助功能权限时周期重试，授权后无需重启即可生效
        if !mediaKeyTap.isRunning && mediaKeyTapAutoStart {
            mediaKeyTapRetryTick += 1
            if mediaKeyTapRetryTick >= 10 {
                mediaKeyTapRetryTick = 0
                if mediaKeyTap.start() {
                    Self.debugLog("tap retry success")
                    UserDefaults.standard.set(true, forKey: "mediaKeyTapActive")
                }
            }
        }

        batteryCheckCounter += 1
        if batteryCheckCounter >= 10 {
            batteryCheckCounter = 0
            checkBattery()
        }

        if let deadline = state.timerDeadline {
            let remain = deadline.timeIntervalSinceNow
            if remain <= 0 {
                state.timerDeadline = nil
                NSSound(named: "Glass")?.play()
                showToast(Activity(kind: .timerDone, text: "专注完成 🎉", until: Date().addingTimeInterval(4)))
            } else {
                state.timerRemaining = remain
                refreshLayout()
            }
        }

        if let estimate = music.currentEstimate() {
            if estimate != state.music {
                state.music = estimate
            }
            // 歌词：歌名变化时重新拉取，按播放进度推进当前行
            if showLyrics {
                // 电台混排标题「XX电台、歌手们 - 歌名」：取 " - " 后段作为歌名去搜索
                var searchTitle = estimate.title
                if let range = searchTitle.range(of: " - ", options: .backwards) {
                    let tail = String(searchTitle[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty { searchTitle = tail }
                }
                let key = "\(searchTitle)|\(estimate.artist)"
                if lyricsKey != key {
                    lyricsKey = key
                    lyrics.loadIfNeeded(title: searchTitle, artist: estimate.artist)
                }
                let line = lyrics.currentLine(position: estimate.position)
                if line != state.lyricLine {
                    state.lyricLine = line
                }
            } else if state.lyricLine != nil {
                state.lyricLine = nil
            }
        }
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pasteboard.changeCount

        var text: String?
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            text = string
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            text = urls.map(\.lastPathComponent).joined(separator: "、")
        }
        guard var text, !text.isEmpty else { return }
        text = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if text.count > 20 { text = String(text.prefix(20)) + "…" }
        showToast(Activity(kind: .clipboard, text: "已复制 \(text)", until: Date().addingTimeInterval(4)))
    }

    private func checkBattery() {
        guard let info = PowerInfo.read() else { return }
        guard let previous = lastCharging else {
            lastCharging = info.charging
            return
        }
        if info.charging != previous {
            let text = info.charging ? "充电中 \(info.percent)%" : "已断开电源 \(info.percent)%"
            showToast(Activity(kind: .battery, text: text, until: Date().addingTimeInterval(4)))
            lastCharging = info.charging
        }
    }

    private func showToast(_ activity: Activity) {
        state.activity = activity
        refreshLayout()
    }

    // MARK: - 音量 / 亮度 HUD

    private func showVolumeHUD(volume: Float, muted: Bool) {
        showToast(Activity(
            kind: .volume,
            text: muted ? "已静音" : "\(Int((volume * 100).rounded()))%",
            until: Date().addingTimeInterval(1.6),
            level: muted ? 0 : Double(volume)
        ))
    }

    private func checkBrightness() {
        guard !brightnessDisabled else { return }
        guard let value = DisplayBrightness.read() else {
            // 偶发读不到（锁屏/显示器休眠）不永久放弃，连续失败才停用
            brightnessNilReads += 1
            if brightnessNilReads <= 3 || brightnessNilReads % 40 == 0 {
                Self.debugLog("brightness read nil #\(brightnessNilReads)")
            }
            if brightnessNilReads > 40 { brightnessDisabled = true }
            return
        }
        brightnessNilReads = 0
        if tickCount <= 3 { Self.debugLog("brightness read ok \(value)") }
        if value == 0 {
            brightnessInvalidReads += 1
            if brightnessInvalidReads > 60 {
                brightnessDisabled = true
            }
            return
        }
        if let last = lastBrightness, abs(value - last) >= 0.01 {
            showToast(Activity(
                kind: .brightness,
                text: "\(Int((value * 100).rounded()))%",
                until: Date().addingTimeInterval(1.6),
                level: value
            ))
        }
        if lastBrightness == nil || abs(value - (lastBrightness ?? -1)) >= 0.001 {
            UserDefaults.standard.set(value, forKey: "brightnessPollValue")
        }
        lastBrightness = value
    }

    // MARK: - 文件暂存

    func handleDragEntered() {
        if !state.expanded {
            state.expanded = true
            refreshLayout()
        }
    }

    func stashFiles(urls: [URL]) {
        let added = stash.stash(urls: urls)
        guard added > 0 else { return }
        state.stashed = stash.files
        showToast(Activity(
            kind: .clipboard,
            text: "已暂存 \(added) 个文件",
            until: Date().addingTimeInterval(3)
        ))
    }

    func unstashAll() {
        stash.unstashAll()
        state.stashed = stash.files
        refreshLayout()
    }

    func copyStashed() {
        let count = stash.copyAllToPasteboard()
        guard count > 0 else { return }
        showToast(Activity(kind: .clipboard, text: "已拷贝 \(count) 个文件", until: Date().addingTimeInterval(2)))
    }

    func trashStashed(_ file: StashedFile) {
        stash.trash(file)
        state.stashed = stash.files
        refreshLayout()
    }

    func openInbox() {
        stash.openInbox()
    }

    func reveal(_ file: StashedFile) {
        stash.reveal(file)
    }

    // MARK: - 交互

    var isExpanded: Bool { state.expanded }

    // MARK: - 触控板手势（悬停岛：双指下拉展开 / 上拉收起 / 左右划切歌）
    // 一次完整手势只触发一次由窗口层的 gestureFired 保证，这里不再做时间节流

    enum SwipeAxis {
        case vertical, horizontal
    }

    func handleSwipe(axis: SwipeAxis, direction: CGFloat) {
        if axis == .vertical {
            if direction > 0, !state.expanded {
                state.expanded = true
                refreshLayout()
            } else if direction < 0, state.expanded {
                state.expanded = false
                refreshLayout()
            }
        } else if state.music != nil {
            // 左右划切歌：向左划（dx<0 转正后）= 下一首
            musicControl(direction > 0 ? .next : .previous)
        }
    }

    func handleHover(_ entered: Bool) {
        isHovering = entered
        if !state.expanded { refreshLayout() }
    }

    func handleClick() {
        if !state.expanded {
            state.expanded = true
            refreshLayout()
        }
    }

    func collapseIfExpanded() {
        if state.expanded {
            state.expanded = false
            refreshLayout()
        }
    }

    func toggleExpanded() {
        state.expanded.toggle()
        refreshLayout()
    }

    func togglePomodoro() {
        if state.timerDeadline != nil {
            state.timerDeadline = nil
        } else {
            state.timerDeadline = Date().addingTimeInterval(25 * 60)
        }
        refreshLayout()
    }

    func musicControl(_ command: MusicCommand) {
        music.send(command)
    }

    // MARK: - 媒体键（隐藏系统 HUD）

    /// 开关偏好：关掉后不再自动重试
    private var mediaKeyTapAutoStart: Bool {
        get { UserDefaults.standard.object(forKey: "hideSystemHUD") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hideSystemHUD") }
    }

    private func activateMediaKeyTap() {
        let trusted = AXIsProcessTrusted()
        if mediaKeyTap.start() {
            Self.debugLog("tap created (trusted=\(trusted))")
            UserDefaults.standard.set(true, forKey: "mediaKeyTapActive")
        } else {
            Self.debugLog("tap create FAILED (trusted=\(trusted))")
        }
    }

    private func handleMediaKey(_ key: MediaKeyTap.Key) -> Bool {
        switch key {
        case .soundUp:
            return volumeWatcher.adjustVolume(1 / 16)
        case .soundDown:
            return volumeWatcher.adjustVolume(-1 / 16)
        case .mute:
            return volumeWatcher.toggleMute()
        case .brightnessUp:
            return adjustBrightness(1 / 16)
        case .brightnessDown:
            return adjustBrightness(-1 / 16)
        }
    }

    private func adjustBrightness(_ delta: Double) -> Bool {
        guard let current = DisplayBrightness.read() ?? lastBrightness else { return false }
        let next = min(1, max(0, current + delta))
        guard DisplayBrightness.set(next) else { return false }
        lastBrightness = next
        showToast(Activity(
            kind: .brightness,
            text: "\(Int((next * 100).rounded()))%",
            until: Date().addingTimeInterval(1.6),
            level: next
        ))
        return true
    }

    func refreshGeometry() {
        if let newGeometry = NotchLocator.best() {
            geometry = newGeometry
            state.notchWidth = newGeometry.notchWidth
            state.notchHeight = newGeometry.notchHeight
            state.hasNotch = newGeometry.hasNotch
            refreshLayout()
        }
    }

    // MARK: - 菜单

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        fillMenu(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fillMenu(menu)
    }

    private func fillMenu(_ menu: NSMenu) {
        let expand = NSMenuItem(
            title: state.expanded ? "收起灵动岛" : "展开灵动岛",
            action: #selector(menuToggleExpand),
            keyEquivalent: ""
        )
        expand.target = self
        menu.addItem(expand)

        menu.addItem(.separator())

        let timer = NSMenuItem(
            title: state.timerDeadline == nil ? "开始 25 分钟专注" : "停止专注计时",
            action: #selector(menuTogglePomodoro),
            keyEquivalent: ""
        )
        timer.target = self
        timer.state = state.timerDeadline == nil ? .off : .on
        menu.addItem(timer)

        menu.addItem(.separator())

        let lyricsItem = NSMenuItem(
            title: "显示歌词",
            action: #selector(menuToggleLyrics),
            keyEquivalent: ""
        )
        lyricsItem.target = self
        lyricsItem.state = showLyrics ? .on : .off
        menu.addItem(lyricsItem)

        let hud = NSMenuItem(
            title: mediaKeyTap.isRunning ? "隐藏系统音量/亮度 HUD（已开启）" : "隐藏系统音量/亮度 HUD（需辅助功能权限）",
            action: #selector(menuToggleMediaKeyTap),
            keyEquivalent: ""
        )
        hud.target = self
        hud.state = mediaKeyTap.isRunning ? .on : .off
        menu.addItem(hud)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "开机自启动", action: #selector(menuToggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let about = NSMenuItem(title: "关于 NotchIsland", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 NotchIsland", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func showContextMenu(_ event: NSEvent) {
        guard let contentView = window.contentView else { return }
        let menu = buildMenu()
        menu.popUp(positioning: nil, at: contentView.convert(event.locationInWindow, from: nil), in: contentView)
    }

    @objc private func menuToggleExpand() { toggleExpanded() }
    @objc private func menuTogglePomodoro() { togglePomodoro() }

    @objc private func menuToggleLyrics() {
        showLyrics.toggle()
        if !showLyrics {
            state.lyricLine = nil
        }
        refreshLayout()
    }

    @objc private func menuToggleMediaKeyTap() {
        if mediaKeyTap.isRunning {
            mediaKeyTap.stop()
            mediaKeyTapAutoStart = false
            UserDefaults.standard.set(false, forKey: "mediaKeyTapActive")
            return
        }
        mediaKeyTapAutoStart = true
        if mediaKeyTap.start() {
            UserDefaults.standard.set(true, forKey: "mediaKeyTapActive")
            return
        }
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "拦截系统自带的音量/亮度提示需要「辅助功能」权限。\n请在系统设置 → 隐私与安全性 → 辅助功能 中打开 NotchIsland；授权后灵动岛会自动重试，无需重启 app。"
        alert.runModal()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuToggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置开机自启动失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func menuAbout() {
        let alert = NSAlert()
        alert.messageText = "灵动岛 NotchIsland"
        alert.informativeText = "把 MacBook 的刘海变成 iPhone 灵动岛。\n版本 0.1.0 · 本地构建"
        alert.runModal()
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }
}
