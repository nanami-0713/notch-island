import SwiftUI

struct IslandView: View {
    @ObservedObject var state: IslandState


    var body: some View {
        ZStack(alignment: .top) {
            background
            if state.expanded {
                expandedContent
                    .transition(.opacity)
            } else if let ext = state.extensionItem {
                collapsedRow(ext)
                    .transition(.opacity)
            } else if state.music != nil {
                musicCollapsedRow
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.28), value: state.expanded)
        .animation(.easeOut(duration: 0.28), value: state.extensionItem)
    }

    private var background: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: state.expanded ? 26 : 12,
            bottomTrailingRadius: state.expanded ? 26 : 12,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 收起态音乐：左侧小封面、右侧随音乐律动的声纹（颜色取自封面主色调）
    private var musicCollapsedRow: some View {
        let np = state.music
        return ZStack {
            Group {
                if let artwork = np?.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.8))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 8)

            EqualizerView(tint: np?.tint ?? .white, playing: np?.playing ?? false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
        }
    }

    /// 收起态：刘海左侧小图标、右侧文字，模拟灵动岛的双活动布局
    /// 窗口是非对称贴边的（图标/文字各距刘海 10pt），两侧留白恒为 sideGap+edgeMargin=12pt
    private func collapsedRow(_ ext: IslandExtension) -> some View {
        ZStack {
            Image(systemName: ext.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 12)
            Text(ext.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
        }
    }

    // MARK: - 展开态

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let activity = state.activity, activity.until > Date() {
                activityRow(activity)
            }
            if state.timerDeadline != nil {
                timerCard
            }
            if let np = state.music {
                musicCard(np)
            }
            if !state.stashed.isEmpty {
                stashCard
            }
            if state.music == nil && state.timerDeadline == nil && state.stashed.isEmpty {
                emptyHint
            }
        }
        .padding(.top, state.notchHeight + 12)  // 内容避开刘海安全区，否则刘海会压住按钮/文字
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func activityRow(_ activity: Activity) -> some View {
        HStack(spacing: 8) {
            if activity.kind == .headphone, let percent = activity.batteryPercent {
                // 耳机电量环：绿>50 橙21~50 红≤20，环心戴耳机图标
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.03, Double(percent) / 100))
                        .stroke(ringColor(percent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "headphones")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 22, height: 22)
            } else {
                Image(systemName: activity.symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(activity.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if let level = activity.level {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(4, proxy.size.width * level))
                    }
                }
                .frame(width: 70, height: 4)
            }
        }
        .foregroundStyle(Color.white.opacity(0.75))
    }

    private func ringColor(_ percent: Int) -> Color {
        switch percent {
        case 51...: return .green
        case 21...50: return .orange
        default: return .red
        }
    }

    private var stashCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("暂存", systemImage: "tray.full.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                actionPill("取出全部") { state.controller?.unstashAll() }
                actionPill("拷贝全部") { state.controller?.copyStashed() }
                actionPill("打开文件夹") { state.controller?.openInbox() }
            }
            ForEach(state.stashed.suffix(4), id: \.inboxName) { file in
                HStack(spacing: 8) {
                    Button {
                        state.controller?.reveal(file)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.6))
                            Text(file.name)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.9))
                                .lineLimit(1)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        state.controller?.trashStashed(file)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if state.stashed.count > 4 {
                Text("还有 \(state.stashed.count - 4) 个文件…")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
    }

    private func actionPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private var timerCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.12)))
            Text(Self.format(state.timerRemaining))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white)
            Spacer()
            Button {
                state.controller?.togglePomodoro()
            } label: {
                Text("停止")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
    }

    private func musicCard(_ np: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let artwork = np.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 46, height: 46)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.8))
                        )
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(np.title.isEmpty ? "未在播放" : np.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    if !np.artist.isEmpty {
                        Text(np.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !np.app.isEmpty {
                    Text(np.app)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: progressWidth(proxy.size.width, np))
                }
            }
            .frame(height: 4)

            HStack {
                Text(Self.format(np.position))
                Spacer()
                Text("-" + Self.format(max(0, np.duration - np.position)))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.45))

            if np.controlsEnabled {
                HStack(spacing: 30) {
                    controlButton("backward.fill", size: 14) { state.controller?.musicControl(.previous) }
                    controlButton(np.playing ? "pause.fill" : "play.fill", size: 20) { state.controller?.musicControl(.playPause) }
                    controlButton("forward.fill", size: 14) { state.controller?.musicControl(.next) }
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("系统限制：此来源仅展示播放信息")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
            }

            if let lyric = state.lyricLine, !lyric.isEmpty {
                Text(lyric)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
    }

    private func progressWidth(_ total: CGFloat, _ np: NowPlaying) -> CGFloat {
        guard np.duration > 0 else { return 0 }
        return total * min(1, max(0, np.position / np.duration))
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(Color.white.opacity(0.5))
            Text("没有正在进行的动态")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
            Text("播放音乐、复制内容，或在菜单里开始专注")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 四条声纹柱：播放时随时间律动（颜色取封面主色调），暂停时静止变暗
struct EqualizerView: View {
    var tint: Color
    var playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(playing ? tint : Color.white.opacity(0.35))
                        .frame(width: 3, height: playing ? barHeight(i, t) : 4)
                }
            }
            .frame(height: 16, alignment: .bottom)
        }
    }

    private func barHeight(_ index: Int, _ t: TimeInterval) -> CGFloat {
        let speed = 2.2 + Double(index) * 0.85
        let phase = Double(index) * 1.7
        return 5 + 10 * abs(sin(t * speed + phase))
    }
}
