import AppKit
import Foundation

/// Agent 会话事件存储：tail ZCode hooks 桥写出的 events.jsonl，
/// 按 session_id 维护状态机，产出"上岛"会话列表（只含干活/待批准，见 AgentSession.isDisplayed）。
/// 轮询而非 FSEvent：文件极小、1s 一拍足够，换来截断/轮转天然可探测
@MainActor
final class AgentEventStore {
    struct Session {
        var project: String
        var phase: AgentPhase
        var startedAt: Date
        var lastEventAt: Date
    }

    /// 桥写出的单行事件（字段见 scripts/agent-hook.sh：只含事件类型/会话/工具名/项目名，无内容）
    struct BridgeEvent: Decodable {
        let ts: Double
        let event: String
        let session_id: String
        let tool: String?
        let project: String?
    }

    private(set) var sessions: [String: Session] = [:]
    private var pollTimer: Timer?
    private var fileOffset: Int64 = 0
    private let eventsURL: URL
    private var onUpdate: (([AgentSession]) -> Void)?
    private let processMonitor = AgentProcessMonitor()
    /// 进程监控最新结果：进程不在 + 长时间无事件 = 会话已死，可清理鬼影
    private var agentAlive = false

    /// macOS 的 cachesDirectory 恒为 ~/Library/Caches，直接拼路径避免抛错 API 进静态初始化
    static let defaultEventsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/agent-island/events.jsonl")

    init(eventsURL: URL = AgentEventStore.defaultEventsURL) {
        self.eventsURL = eventsURL
    }

    func start(onUpdate: @escaping ([AgentSession]) -> Void) {
        self.onUpdate = onUpdate
        replayExisting()
        processMonitor.start { [weak self] alive in
            Task { @MainActor [weak self] in self?.agentAlive = alive }
        }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollOnce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        processMonitor.stop()
    }

    /// 上岛会话：过滤 + 排序（待批准优先，其次存活更久的在前）
    func displayedSessions(now: Date = Date()) -> [AgentSession] {
        sessions.map { id, s in
            AgentSession(id: id, project: s.project, phase: s.phase,
                         elapsed: now.timeIntervalSince(s.startedAt))
        }
        .filter(\.isDisplayed)
        .sorted { a, b in
            if (a.phase == .permissionPending) != (b.phase == .permissionPending) {
                return a.phase == .permissionPending
            }
            return a.elapsed > b.elapsed
        }
    }

    // MARK: - 内部

    /// 启动时回放日志尾部：app 重启后岛能立即反映进行中的会话，不丢状态
    private func replayExisting() {
        guard let data = try? Data(contentsOf: eventsURL) else { return }
        let tail = String(decoding: data.suffix(256 * 1024), as: UTF8.self)
        for line in tail.split(separator: "\n") {
            apply(line: String(line))
        }
        fileOffset = Int64(data.count)
        publish()
    }

    private func pollOnce() {
        let size = Int64((try? eventsURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if size < fileOffset { fileOffset = 0 }   // 截断/轮转 → 重读
        if size > fileOffset {
            if let handle = try? FileHandle(forReadingFrom: eventsURL) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: UInt64(fileOffset))
                if let data = try? handle.readToEnd() {
                    fileOffset += Int64(data.count)
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                        apply(line: String(line))
                    }
                }
            }
        }
        publish()
    }

    private func publish() {
        maintain(now: Date())
        onUpdate?(displayedSessions())
    }

    /// 供自测直接注入事件行（--selftest-agent）
    func ingest(line: String) { apply(line: line) }

    private func apply(line: String) {
        guard let data = line.data(using: .utf8),
              let ev = try? JSONDecoder().decode(BridgeEvent.self, from: data),
              !ev.session_id.isEmpty
        else { return }
        let date = Date(timeIntervalSince1970: ev.ts)
        var s = sessions[ev.session_id]
            ?? Session(project: ev.project ?? "agent", phase: .thinking,
                       startedAt: date, lastEventAt: date)
        if let p = ev.project, !p.isEmpty { s.project = p }
        s.lastEventAt = date
        switch ev.event {
        case "SessionStart", "UserPromptSubmit":
            s.phase = .thinking
        case "PreToolUse":
            s.phase = .running((ev.tool?.isEmpty == false) ? ev.tool! : "Tool")
        case "PermissionRequest":
            s.phase = .permissionPending
        case "PostToolUse", "PostToolUseFailure":
            // 批准/拒绝都会走到这里：状态离开 permissionPending
            s.phase = .thinking
        case "Stop":
            s.phase = .waitingInput
        default:
            break
        }
        sessions[ev.session_id] = s
    }

    /// 会话维护：没有 SessionEnd 事件，全靠沉默时长 + 进程 liveness 推断
    private func maintain(now: Date) {
        for (id, s) in sessions {
            let silence = now.timeIntervalSince(s.lastEventAt)
            if !agentAlive && silence > 180 {
                sessions.removeValue(forKey: id)          // CLI 已退出且 3 分钟无事件 → 结束
            } else if s.phase != .waitingInput && silence > 15 * 60 {
                sessions[id]?.phase = .waitingInput       // 干活态沉默 15 分钟 → 降级停靠
            } else if s.phase == .waitingInput && silence > 6 * 3600 {
                sessions.removeValue(forKey: id)          // 停靠超 6 小时 → 清理
            }
        }
    }
}

// MARK: - 桥安装（菜单调用）

enum AgentBridge {
    static var isInstalled: Bool {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".zcode/cli/config.json")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.contains("agent-island/agent-hook.sh")
    }

    /// 运行安装/卸载脚本（打包 app 内含 Resources/install-agent-hook.sh）
    static func run(_ mode: String) -> String {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("install-agent-hook.sh").path,
              FileManager.default.isExecutableFile(atPath: script) else {
            return "未找到安装脚本：请从源码目录运行 scripts/install-agent-hook.sh"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, mode]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "运行失败：\(error.localizedDescription)"
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return process.terminationStatus == 0 ? out : (out.isEmpty ? "退出码 \(process.terminationStatus)" : out)
    }
}

// MARK: - 状态机自测（--selftest-agent，不启动 app）

enum AgentSelfTest {
    @MainActor
    static func run() -> Bool {
        let store = AgentEventStore(eventsURL: URL(fileURLWithPath: "/dev/null"))
        var failures = 0
        func feed(_ json: String) { store.ingest(line: json) }
        func expect(_ label: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL")  \(label)")
            if !condition { failures += 1 }
        }

        feed(#"{"ts":100,"event":"SessionStart","session_id":"a","tool":"","project":"alpha"}"#)
        feed(#"{"ts":110,"event":"UserPromptSubmit","session_id":"a","tool":"","project":"alpha"}"#)
        expect("干活会话上岛", store.displayedSessions().count == 1)

        feed(#"{"ts":120,"event":"PreToolUse","session_id":"a","tool":"Bash","project":"alpha"}"#)
        expect("工具态 = running(Bash)", store.displayedSessions().first?.phase == .running("Bash"))

        feed(#"{"ts":130,"event":"PermissionRequest","session_id":"a","tool":"Write","project":"alpha"}"#)
        expect("待批准态上岛", store.displayedSessions().first?.phase == .permissionPending)

        feed(#"{"ts":131,"event":"PostToolUse","session_id":"a","tool":"Write","project":"alpha"}"#)
        expect("批准后回到 thinking", store.displayedSessions().first?.phase == .thinking)

        feed(#"{"ts":200,"event":"SessionStart","session_id":"b","tool":"","project":"beta"}"#)
        feed(#"{"ts":210,"event":"PermissionRequest","session_id":"b","tool":"Edit","project":"beta"}"#)
        let displayed = store.displayedSessions()
        expect("两个会话都在岛", displayed.count == 2)
        expect("待批准排最前", displayed.first?.id == "b")

        feed(#"{"ts":300,"event":"Stop","session_id":"b","tool":"","project":"beta"}"#)
        expect("Stop 后停靠不上岛", store.displayedSessions().allSatisfy { $0.id != "b" })

        feed(#"{"ts":400,"event":"Stop","session_id":"a","tool":"","project":"alpha"}"#)
        expect("全部停靠 → 岛消失", store.displayedSessions().isEmpty)
        expect("主会话选择对空列表返回 nil", AgentSession.primary(of: []) == nil)

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        return failures == 0
    }
}
