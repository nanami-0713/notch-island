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
        case clipboard, battery, timerDone, volume, brightness
    }

    var kind: Kind
    var text: String
    var until: Date
    var level: Double?

    init(kind: Kind, text: String, until: Date, level: Double? = nil) {
        self.kind = kind
        self.text = text
        self.until = until
        self.level = level
    }

    var symbol: String {
        switch kind {
        case .clipboard: return "doc.on.doc.fill"
        case .battery: return "battery.100.bolt"
        case .timerDone: return "checkmark.circle.fill"
        case .volume: return "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        }
    }
}

/// 收起状态下贴在刘海两侧的小字内容：左侧图标 + 右侧文字
struct IslandExtension: Equatable {
    var symbol: String
    var text: String
    var textWidth: CGFloat
}

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var music: NowPlaying?
    @Published var activity: Activity?
    @Published var extensionItem: IslandExtension?
    @Published var timerDeadline: Date?
    @Published var timerRemaining: Double = 0
    @Published var currentWidth: CGFloat = 0
    @Published var stashed: [StashedFile] = []
    @Published var lyricLine: String?

    var notchWidth: CGFloat = 179
    var notchHeight: CGFloat = 32
    var hasNotch = true

    weak var controller: IslandController?
}
