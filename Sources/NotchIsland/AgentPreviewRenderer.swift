import AppKit
import SwiftUI

/// M1 设计验收专用：把三态假数据视图离屏渲染成 PNG（不启动 app、无需录屏权限）。
/// 产出两张拼板：收起态呼吸点分镜（busy 三相位 + waiting 定格）、展开态（常规 + 溢出折叠）
@MainActor
enum AgentPreviewRenderer {

    static func run(outputDir: String) {
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sessions = AgentSession.preview
        let primary = sessions[0]   // 干活主会话（分镜用）；真实收起态按 AgentSession.primary() 取待批准优先

        // 收起态拼板：三帧干活呼吸分镜 + 一帧「待批准为主会话」的定格态
        let collapsedTiles = VStack(spacing: 14) {
            ForEach([0.0, 0.8, 1.6], id: \.self) { t in
                collapsedTile(row: AgentCollapsedRowStatic(
                    session: primary, anyBusy: true, dotT: t))
            }
            collapsedTile(row: AgentCollapsedRowStatic(
                session: sessions[1], anyBusy: false, dotT: 0))
        }
        save(collapsedTiles, name: "m1-sheet-collapsed.png", to: dir)

        // 展开态拼板：常规（含待批准空心环、停靠会话已过滤）+ 溢出折叠
        let expandedTiles = VStack(spacing: 14) {
            expandedTile(card: AgentExpandedCard(sessions: sessions))
            expandedTile(card: AgentExpandedCard(sessions: AgentSession.previewOverflow))
        }
        save(expandedTiles, name: "m1-sheet-expanded.png", to: dir)
    }

    // MARK: - 拼板元素

    /// 收起态岛体：440×32，上圆角 0（与物理刘海融合）、下圆角 12，同 IslandView
    private static func collapsedTile(row: some View) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 12,
            bottomTrailingRadius: 12, topTrailingRadius: 0, style: .continuous
        )
        .fill(Color.black)
        .frame(width: 440, height: 32)
        .overlay(row)
    }

    /// 展开态岛体：400 宽、高度自适应，上圆角 0、下 26；顶部留 notchHeight+12 安全区。
    /// 卡片撑起尺寸，黑色岛体做 background 跟随（shape 无固有尺寸，不能反过来 overlay）
    private static func expandedTile(card: some View) -> some View {
        card
            .padding(.top, 32 + 12)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(width: 400, alignment: .topLeading)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 26,
                    bottomTrailingRadius: 26, topTrailingRadius: 0, style: .continuous
                )
                .fill(Color.black)
            )
    }

    /// 收起态的静态替身：呼吸点定格在指定时刻，其余与 AgentCollapsedRow 完全一致
    private struct AgentCollapsedRowStatic: View {
        var session: AgentSession
        var anyBusy: Bool
        var dotT: TimeInterval

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
                    BreathingDotsShape(t: dotT, animate: anyBusy)
                    Text(AgentCollapsedRow.format(session.elapsed))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.85))
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
            }
        }
    }

    // MARK: - 出图

    private static func save(_ view: some View, name: String, to dir: URL) {
        // 浅色桌面渐变做底：衬托黑色岛体轮廓，更接近真实菜单栏观感
        let sheet = ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.93, blue: 0.95),
                    Color(red: 0.78, green: 0.78, blue: 0.83),
                ],
                startPoint: .top, endPoint: .bottom
            )
            view.padding(.top, 10).padding(.horizontal, 12)
        }
        .fixedSize()

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write("render failed: \(name)\n".data(using: .utf8)!)
            return
        }
        try? png.write(to: dir.appendingPathComponent(name))
        print(dir.appendingPathComponent(name).path)
    }
}
