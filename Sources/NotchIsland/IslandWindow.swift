import AppKit
import SwiftUI

/// 无边框、不抢焦点：点击刘海区域不会打断当前正在用的 app
@MainActor
final class IslandWindow: NSWindow {
    weak var controller: IslandController?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // 双指滚动累计量（悬停岛上触发）
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    private var lastGestureAt = Date.distantPast
    private var gestureLocked: GestureAxis = .none
    private var gestureFired = false  // 一次完整手势（接触→抬起）只触发一次

    private enum GestureAxis {
        case none, horizontal, vertical
    }

    // NSHostingView 会吞掉 mouseDown 导致不冒泡，因此收起态的点击/右键在窗口层直接处理
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let controller, !controller.isExpanded {
            controller.handleClick()
            return
        }
        if event.type == .rightMouseDown, let controller {
            controller.showContextMenu(event)
            return
        }
        if event.type == .scrollWheel, let controller {
            handleScroll(event, controller: controller)
            return
        }
        super.sendEvent(event)
    }

    /// 触控板手势：双指下拉展开 / 上拉收起 / 左右划切歌
    /// 累计超阈值判一次手势、锁定主轴；惯性阶段忽略 + 触发后置位 gestureFired，
    /// 直到 phase==began（新一次触摸）才复位——保证一次划动只切一首/只展开收起一次。
    private func handleScroll(_ event: NSEvent, controller: IslandController) {
        let isTrackpad = event.phase != [] || event.momentumPhase != []

        // 惯性滚动：手指已抬起，属于上一次手势的余波，只用于延续视觉、不触发动作
        if event.phase == [], event.momentumPhase != [] {
            return
        }

        if event.phase == .began {
            // 新手势开始
            scrollAccumX = 0
            scrollAccumY = 0
            gestureLocked = .none
            gestureFired = false
        }

        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !isTrackpad {
            // 鼠标滚轮没有相位：每格固定步长，天然一格格触发
            dx = dx == 0 ? 0 : (dx > 0 ? 18 : -18)
            dy = dy == 0 ? 0 : (dy > 0 ? 18 : -18)
        }
        // 触控板自然滚动：内容坐标系，dy>0 是下拉
        dx = -dx

        scrollAccumX += dx
        scrollAccumY += dy
        lastGestureAt = Date()

        let threshold: CGFloat = 28
        if gestureLocked == .none {
            if abs(scrollAccumX) > threshold && abs(scrollAccumX) > abs(scrollAccumY) * 1.3 {
                gestureLocked = .horizontal
            } else if abs(scrollAccumY) > threshold && abs(scrollAccumY) > abs(scrollAccumX) * 1.3 {
                gestureLocked = .vertical
            }
        }

        guard !gestureFired, gestureLocked != .none else { return }
        switch gestureLocked {
        case .vertical:
            guard abs(scrollAccumY) > threshold else { return }
            gestureFired = true
            controller.handleSwipe(axis: .vertical, direction: scrollAccumY > 0 ? 1 : -1)
        case .horizontal:
            guard abs(scrollAccumX) > threshold else { return }
            gestureFired = true
            controller.handleSwipe(axis: .horizontal, direction: scrollAccumX > 0 ? 1 : -1)
        case .none:
            break
        }
    }
}

@MainActor
final class IslandContainerView: NSView {
    weak var controller: IslandController?
    var hostingView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 拖文件到灵动岛 = 暂存
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              urls.contains(where: \.isFileURL) else { return [] }
        controller?.handleDragEntered()
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              urls.contains(where: \.isFileURL) else { return false }
        controller?.stashFiles(urls: urls)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        controller?.handleClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(event)
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.handleHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.handleHover(false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }
}
