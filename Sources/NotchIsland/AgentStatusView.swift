import SwiftUI

// MARK: - 数据模型（M1 为纯展示组件 + 假数据；M2 起由 hooks 事件流 / 进程表填充）

/// 一个 agent 会话的工作状态。v1 只做状态感知：不含 token、成本、模型名
enum AgentPhase: Equatable {
    case thinking                 // UserPromptSubmit 之后、首个工具调用之前
    case running(String)          // PreToolUse..PostToolUse 之间，值为工具名
    case permissionPending        // PermissionRequest 已触发、等待用户批准
    case waitingInput             // Stop 之后，等下一条指令——不上岛

    var label: String {
        switch self {
        case .thinking: return "思考中"
        case .running(let tool): return "执行 \(tool)"
        case .permissionPending: return "待批准"
        case .waitingInput: return "等待输入"
        }
    }

    var isBusy: Bool {
        switch self {
        case .thinking, .running: return true
        case .permissionPending, .waitingInput: return false
        }
    }
}

extension AgentSession {
    /// 展示策略：岛空间有限，只通报「正在干活」与「等待批准」两类会话；
    /// Stop 之后停靠的会话不上岛——全部空闲时岛整个消失（无事即无形）
    var isDisplayed: Bool {
        switch phase {
        case .thinking, .running, .permissionPending: return true
        case .waitingInput: return false
        }
    }

    /// 收起态主会话：待批准优先（需要用户介入），否则取最近干活的
    static func primary(of displayed: [AgentSession]) -> AgentSession? {
        displayed.first(where: { $0.phase == .permissionPending })
            ?? displayed.first(where: { $0.phase.isBusy })
            ?? displayed.first
    }
}

struct AgentSession: Identifiable, Equatable {
    var id: String
    var project: String            // 项目目录 basename
    var phase: AgentPhase
    var elapsed: TimeInterval

    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id && lhs.project == rhs.project
            && lhs.phase == rhs.phase && abs(lhs.elapsed - rhs.elapsed) < 1
    }
}

// MARK: - 收起态

/// 三个呼吸点：agent 干活时的唯一动效，刻意比声纹安静（正弦 0.28→1.0，周期 2.4s）。
/// 全部会话都在等待输入时定格为暗点——动与静即状态，不用颜色
struct BreathingDots: View {
    var animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            BreathingDotsShape(t: timeline.date.timeIntervalSinceReferenceDate, animate: animate)
        }
    }
}

/// BreathingDots 的纯函数形态：给定时刻 t 渲染，供预览分镜离屏出图
struct BreathingDotsShape: View {
    var t: TimeInterval
    var animate: Bool

    private static let period: Double = 2.4

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(opacity(i)))
                    .frame(width: 4, height: 4)
            }
        }
    }

    private func opacity(_ i: Int) -> Double {
        guard animate else { return 0.35 }
        let phase = t.truncatingRemainder(dividingBy: Self.period)
        let wave = 0.5 * (1 + sin((phase - Double(i) * 0.55) / Self.period * 2 * .pi))
        return 0.28 + 0.57 * wave   // 峰值 0.85：保持比声纹安静，不抢音乐岛的视觉焦点
    }
}

/// 收起态：左翼 terminal 符号 + 项目名，右翼呼吸点 + 等宽时长（映射音乐岛的「左封面/右声纹」）
struct AgentCollapsedRow: View {
    var session: AgentSession      // 最近活跃的会话
    var anyBusy: Bool              // 任意会话在干活则呼吸，否则定格

    var body: some View {
        ZStack {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                Text(session.project)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 12)

            HStack(spacing: 6) {
                BreathingDots(animate: anyBusy)
                Text(Self.format(session.elapsed))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.85))
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - 展开态

/// 展开态：每会话一行（状态点 / 项目 / 状态词 / 时长），超过 3 行折叠计数，不滚动
struct AgentExpandedCard: View {
    var sessions: [AgentSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sessions.prefix(3)) { session in
                row(session)
            }
            if sessions.count > 3 {
                Text("还有 \(sessions.count - 3) 个会话…")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
    }

    private func row(_ s: AgentSession) -> some View {
        HStack(spacing: 8) {
            // 干活=实心点，待批准=空心环：动与静之外的第二种单色区分，不引颜色
            Group {
                if s.phase == .permissionPending {
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 6, height: 6)
                } else {
                    Circle()
                        .fill(Color.white.opacity(s.phase.isBusy ? 1.0 : 0.35))
                        .frame(width: 6, height: 6)
                }
            }
            Text(s.project)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.95))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(s.phase.label)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
                .frame(minWidth: 72, alignment: .trailing)   // 状态词列左端近似对齐，右端仍贴时长
            Text(Self.format(s.elapsed))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.35))   // 与状态词拉开亮度差，层级一眼可辨
                .fixedSize()
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        AgentCollapsedRow.format(interval)
    }
}

// MARK: - 假数据（M1 验收用，M2 接真实信号后删除）

extension AgentSession {
    /// 原始会话全景（含不上岛的停靠会话），验收过滤语义用
    static var previewAll: [AgentSession] {
        [
            AgentSession(id: "s1", project: "zcode-usage", phase: .running("Bash"), elapsed: 724),
            AgentSession(id: "s2", project: "dsh-desktop", phase: .permissionPending, elapsed: 312),
            AgentSession(id: "s3", project: "oss-pipeline", phase: .thinking, elapsed: 95),
            AgentSession(id: "s4", project: "notch-island", phase: .waitingInput, elapsed: 2597),
        ]
    }

    /// 上岛会话 = previewAll.filter(isDisplayed)：停靠的 notch-island 不见
    static var preview: [AgentSession] {
        previewAll.filter(\.isDisplayed)
    }

    static var previewOverflow: [AgentSession] {
        preview + [
            AgentSession(id: "s5", project: "Maccy", phase: .running("Edit"), elapsed: 51),
            AgentSession(id: "s6", project: "modlens", phase: .running("Read"), elapsed: 8),
        ]
    }
}
