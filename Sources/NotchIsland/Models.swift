import AppKit
import Foundation
import SwiftUI

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var app: String
    var duration: Double
    var position: Double
    var playing: Bool
    var controlsEnabled: Bool
    var artwork: NSImage?
    var tint: Color?

    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.app == rhs.app
            && abs(lhs.duration - rhs.duration) < 0.01
            && abs(lhs.position - rhs.position) < 0.3
            && lhs.playing == rhs.playing
            && lhs.controlsEnabled == rhs.controlsEnabled
    }
}

struct Activity: Equatable {
    enum Kind {
        case clipboard, battery, timerDone, volume, brightness, headphone, agent
    }

    var kind: Kind
    var text: String
    var until: Date
    var level: Double?
    /// 耳机电量百分比（headphone 专用，渲染电环）
    var batteryPercent: Int?

    init(kind: Kind, text: String, until: Date, level: Double? = nil, batteryPercent: Int? = nil) {
        self.kind = kind
        self.text = text
        self.until = until
        self.level = level
        self.batteryPercent = batteryPercent
    }

    var symbol: String {
        switch kind {
        case .clipboard: return "doc.on.doc.fill"
        case .battery: return "battery.100.bolt"
        case .timerDone: return "checkmark.circle.fill"
        case .volume: return "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .headphone: return "headphones"
        case .agent: return "terminal"
        }
    }
}

/// 收起状态下贴在刘海两侧的小字内容：左侧图标 + 右侧文字
struct IslandExtension: Equatable {
    var symbol: String
    var text: String
    var textWidth: CGFloat
    /// 计时进度 0~1（专注模式专用）：非 nil 时收起态改用「左侧图标+倒计时、右侧迷你进度条」布局
    var progress: Double?
}

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var music: NowPlaying?
    @Published var activity: Activity?
    @Published var extensionItem: IslandExtension?
    @Published var timerDeadline: Date?
    @Published var timerRemaining: Double = 0
    /// 本次专注的总时长（收起态迷你进度条的分母）
    var timerTotal: TimeInterval = 25 * 60
    @Published var currentWidth: CGFloat = 0
    @Published var stashed: [StashedFile] = []
    @Published var lyricLine: String?
    /// Agent 状态岛：只含「正在干活 / 等待批准」的会话（过滤规则见 AgentSession.isDisplayed）
    @Published var agentSessions: [AgentSession] = []

    /// 有会话在等批准但收起态正被音乐/计时等内容占用时，左翼最外侧亮 4pt 注意点
    var agentNeedsAttention: Bool {
        agentSessions.contains { $0.phase == .permissionPending }
    }

    var notchWidth: CGFloat = 179
    var notchHeight: CGFloat = 32
    var hasNotch = true

    weak var controller: IslandController?
}
