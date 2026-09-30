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
    private let headphones = HeadphoneWatcher()
    private let agentStore = AgentEventStore()
    private var lyricsKey: String?
    private var mediaKeyTapRetryTick = 0
    private var brightnessNilReads = 0
    private var tickCount = 0

    /// 歌词开关（默认开）
    private var showLyrics: Bool {
        get { UserDefaults.standard.object(forKey: "showLyrics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showLyrics") }
    }

    /// Agent 状态岛开关（默认开；桥没装时岛自然空白，零成本）
    private var agentEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "showAgentStatus") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showAgentStatus") }
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
    /// 专注开始的"弹出"进行中：弹簧接近弹出目标时拉回真实目标（见 bounce/springStep）
    private var popActive = false

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
        if agentEnabled {
            startAgentStore()
        }
    }

    private func startAgentStore() {
        agentStore.start { [weak self] sessions in
            guard let self else { return }
            self.state.agentSessions = sessions
            self.refreshLayout()
        }
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

        // 耳机连接动画：连上弹「🎧 + 电量」，断开弹提示
        headphones.onConnected = { [weak self] snapshot in
            self?.showHeadphoneToast(snapshot: snapshot, connected: true)
        }
        headphones.onDisconnected = { [weak self] name in
            self?.showToast(Activity(
                kind: .headphone,
                text: "\(name) 已断开",
                until: Date().addingTimeInterval(3)
            ))
        }
        headphones.start()

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
        agentStore.stop()
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
        // 弹出进行中目标由 bounce 独占：专注计时每 0.5s 的 refreshLayout 会把
        // 弹出目标立刻改写回真实值，弹出从未发生（实测曲线峰值被封在 327）——屏蔽之
        if popActive { return }
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

        // 弹出阶段：接近弹出目标即拉回真实目标，形成"弹出→回落"的确定幅度一跳
        if popActive, currentW >= targetW - 6 {
            popActive = false
            refreshLayout()
        }

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
                content += 52  // 环形进度 48 + 呼吸空间
                sections += 1
            }
            if state.music != nil {
                content += 140
                sections += 1
            }
            if showLyrics && state.music != nil && state.lyricLine != nil {
                content += 24
            }
            if !state.agentSessions.isEmpty {
                // 标题行 18 + 间距 8 + 每行约 22 + 溢出页脚 14
                content += 18 + 8 + CGFloat(min(3, state.agentSessions.count)) * 22
                if state.agentSessions.count > 3 { content += 14 }
                sections += 1
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
            // 左右对称：两翼等宽（取两侧内容较大者 + 边距），文字超长已在 extensionContent 截断
            if ext.progress != nil {
                // 专注模式：最左「月亮+倒计时」、右侧迷你环形进度，两翼取较大内容等宽
                let sideW = max(sideGap + 12 + 5 + ext.textWidth + edgeMargin,
                                sideGap + 16 + edgeMargin)
                leftExtent = sideW
                rightExtent = sideW
            } else {
                let sideW = max(14, ext.textWidth) + sideGap + edgeMargin
                leftExtent = sideW
                rightExtent = sideW
            }
        } else if state.music != nil {
            // 音乐：左右翼精确镜像（各 8 + 22 + 8），岛体居中、双翼对称
            leftExtent = sideGap + 22 + 8
            rightExtent = sideGap + 22 + 8
        } else if !state.agentSessions.isEmpty,
                  let primary = AgentSession.primary(of: state.agentSessions) {
            // Agent：左翼符号+项目名、右翼呼吸点+时长，双翼取较大内容等宽（音乐岛同构）
            let project = Self.clampText(primary.project, maxWidth: 64)
            let timeText = AgentCollapsedRow.format(primary.elapsed)
            let left = 11 + 5 + Self.textWidth(project)                    // 符号 + 间距 + 项目名
            let right = 19 + 6 + Self.textWidth(timeText)                  // 三呼吸点 19pt + 间距 + 时长
            let sideW = max(left, right) + sideGap + edgeMargin
            leftExtent = sideW
            rightExtent = sideW
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
            let remain = max(0, deadline.timeIntervalSinceNow)
            let text = Self.formatCountdown(remain)
            let progress = state.timerTotal > 0 ? 1 - remain / state.timerTotal : 0
            return IslandExtension(symbol: "timer", text: text, textWidth: Self.textWidth(text),
                                   progress: min(max(progress, 0), 1))
        }
        if let activity = state.activity, activity.until > Date() {
            let text = Self.clampText(activity.text)
            return IslandExtension(symbol: activity.symbol, text: text, textWidth: Self.textWidth(text))
        }
        if !state.stashed.isEmpty {
            let text = Self.clampText("\(state.stashed.count) 个文件")
            return IslandExtension(symbol: "tray.full.fill", text: text, textWidth: Self.textWidth(text))
        }
        // 音乐收起态改用「封面 + 声纹」视图，不再用文字
        return nil
    }

    /// 收起态文字翼上限 64pt：双翼对称布局下文字过长会把岛撑得过宽，超长截断加省略号
    private static func clampText(_ text: String, maxWidth: CGFloat = 64) -> String {
        func width(_ s: String) -> CGFloat { textWidth(s) }
        guard width(text) > maxWidth else { return text }
        var count = text.count
        while count > 1 {
            let candidate = String(text.prefix(count - 1)) + "…"
            if width(candidate) <= maxWidth { return candidate }
            count -= 1
        }
        return "…"
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
        // 状态项窗口与岛体同层（layer 25），系统重排后可能压到岛体上方、盖住封面/声纹，
        // 每拍把岛体重新提到同级最前
        window.orderFrontRegardless()
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

        // Agent 岛的时长每拍重算（EventSession.elapsed 是派生值）；空列表时跳过省一次对象图发布
        if agentEnabled, !agentStore.sessions.isEmpty {
            state.agentSessions = agentStore.displayedSessions()
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

    private func showHeadphoneToast(snapshot: HeadphoneWatcher.Snapshot, connected: Bool) {
        let batteryText: String
        if let percent = snapshot.percent {
            batteryText = " \(percent)%"
        } else {
            batteryText = ""
        }
        showToast(Activity(
            kind: .headphone,
            text: "\(snapshot.name)\(batteryText)",
            until: Date().addingTimeInterval(5),
            batteryPercent: snapshot.percent
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
        let starting = state.timerDeadline == nil
        if starting {
            state.timerDeadline = Date().addingTimeInterval(25 * 60)
            state.timerTotal = 25 * 60
        } else {
            state.timerDeadline = nil
        }
        runFocusShortcut(starting ? "开勿扰" : "关勿扰")
        refreshLayout()
        bounce(starting: starting)
    }

    /// 可选系统勿扰桥：macOS 26 上第三方读不到系统专注/勿扰状态（Assertions.json 已废弃、
    /// 控制中心 AX 封锁、SDK 无公开 API），但 Shortcuts CLI 可以驱动它。用户若创建了
    /// 名为「开勿扰」/「关勿扰」的快捷指令（各含一个"设置专注模式"动作），岛开关专注时
    /// 会同步调起；没有则静默跳过，零配置不影响使用。
    private func runFocusShortcut(_ name: String) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    Self.debugLog("focus shortcut '\(name)' not present or failed (\(process.terminationStatus))")
                }
            } catch {
                Self.debugLog("focus shortcut '\(name)' spawn error: \(error.localizedDescription)")
            }
        }
    }

    /// 专注开始的小交互：把弹簧目标临时推高 30pt，弹簧接近时由 springStep 拉回真实目标，
    /// 岛体先弹出 ~24pt 再回落，幅度确定、肉眼明显。停止方向本身即快速收拢 +
    /// 专注行缩放退场，不再叠加。宽度变化由居中公式自动保持居中。
    private func bounce(starting: Bool) {
        guard starting else { return }
        popActive = true
        targetW += 30
        startSpring()
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
            title: state.timerDeadline == nil ? "开始专注 · 勿扰 25 分钟" : "停止专注 · 勿扰",
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

        let agent = NSMenuItem(title: "Agent 状态岛", action: #selector(menuToggleAgent), keyEquivalent: "")
        agent.target = self
        agent.state = agentEnabled ? .on : .off
        menu.addItem(agent)

        let bridge = NSMenuItem(
            title: AgentBridge.isInstalled ? "ZCode 状态桥（已连接）" : "安装 ZCode 状态桥…",
            action: #selector(menuToggleBridge),
            keyEquivalent: ""
        )
        bridge.target = self
        menu.addItem(bridge)

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

    @objc private func menuToggleAgent() {
        agentEnabled.toggle()
        if agentEnabled {
            startAgentStore()
        } else {
            agentStore.stop()
            state.agentSessions = []
        }
        refreshLayout()
    }

    @objc private func menuToggleBridge() {
        let mode = AgentBridge.isInstalled ? "uninstall" : "install"
        let output = AgentBridge.run(mode).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = mode == "install" ? "状态桥已安装" : "状态桥已卸载"
        Self.debugLog("bridge \(mode): \(output)")
        showToast(Activity(kind: .agent, text: text, until: Date().addingTimeInterval(3)))
    }

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
        alert.informativeText = "把 MacBook 的刘海变成 iPhone 灵动岛。\n版本 0.3.0 · 本地构建"
        alert.runModal()
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }
}
