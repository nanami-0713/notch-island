import AppKit
import ApplicationServices

/// 菜单栏占用快照：刘海两侧各剩多少连续空间、多少状态图标被刘海/岛压住。
/// 坐标均为屏幕点（CG 全局坐标，原点左上，y 向下）。
struct MenuBarSnapshot: Equatable {
    /// 刘海左缘到左侧最近占用物（状态项/应用菜单）的距离
    var freeLeft: CGFloat = 300
    /// 刘海右缘到右侧最近状态项的距离
    var freeRight: CGFloat = 300
    /// 系统塞进刘海底下的状态图标数（macOS 的老毛病：右侧状态区溢出就藏进刘海）
    var hiddenCount: Int = 0
    /// 条带内全部状态项窗口（含窗口 ID，按 minX 排序）；让路占位窗口的精确排除由
    /// 控制器按 ID 完成——按宽度匹配会把宽度相近的真实图标误伤（实测 36 占位 vs 32 图标）
    var items: [MenuBarItem] = []

    /// 探测失败/无刘海时的兜底：不约束翼展（与旧版固定翼展行为一致）
    static let unknown = MenuBarSnapshot()
}

/// 菜单栏条带内的一个状态项窗口
struct MenuBarItem: Equatable {
    let id: Int64
    let frame: CGRect
}

/// 让顶部任务栏"自动识别刘海块与灵动岛"的探测器：
/// 枚举状态栏层的窗口（第三方 NSStatusItem 与系统项都是独立窗口，layer 25），
/// 量出刘海两侧真实空隙，岛的两翼据此伸缩，任何内容都不再压住菜单栏图标。
enum MenuBarProbe {
    /// 垂直方向容差：状态项在菜单栏条带内居中，比刘海略矮
    private static let bandSlack: CGFloat = 8
    /// 窗口尺寸过滤：状态项一般 14~60pt 宽（文字项更宽），过高过宽的是别的浮层
    private static let minItemWidth: CGFloat = 6
    private static let maxItemWidth: CGFloat = 220
    private static let minItemHeight: CGFloat = 10
    private static let maxItemHeight: CGFloat = 44

    static func probe(geometry: ScreenGeometry) -> MenuBarSnapshot {
        guard geometry.hasNotch, let primary = NSScreen.screens.first else { return .unknown }
        let screen = geometry.screen
        let primaryHeight = primary.frame.maxY  // AppKit→CG 全局坐标的翻转基准

        let notchAppKit = NSRect(
            x: screen.frame.midX - geometry.notchWidth / 2,
            y: screen.frame.maxY - geometry.notchHeight,
            width: geometry.notchWidth,
            height: geometry.notchHeight
        )
        let notch = CGRect(
            x: notchAppKit.minX,
            y: primaryHeight - notchAppKit.maxY,
            width: notchAppKit.width,
            height: notchAppKit.height
        )
        let bandTop = notch.minY
        let bandBottom = notch.maxY + bandSlack

        var snapshot = MenuBarSnapshot.unknown

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return snapshot }

        for info in list {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 25 else { continue }  // kCGStatusBarWindowLevel：状态项窗口
            // 自己的状态项和岛体窗口都在这一层，排除自身进程
            if let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == getpid() { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            // 只看菜单栏这一条带里的窗口
            guard frame.midY >= bandTop, frame.midY <= bandBottom else { continue }
            guard frame.width >= minItemWidth, frame.width <= maxItemWidth,
                  frame.height >= minItemHeight, frame.height <= maxItemHeight else { continue }

            let windowID = info[kCGWindowNumber as String] as? Int64 ?? 0
            snapshot.items.append(MenuBarItem(id: windowID, frame: frame))
            if frame.maxX <= notch.minX + 1 {
                snapshot.freeLeft = min(snapshot.freeLeft, notch.minX - frame.maxX)
            } else if frame.minX >= notch.maxX - 1 {
                snapshot.freeRight = min(snapshot.freeRight, frame.minX - notch.maxX)
            }
            if frame.intersects(notch) {
                snapshot.hiddenCount += 1
            }
        }
        snapshot.items.sort { $0.frame.minX < $1.frame.minX }

        // 应用菜单（文件/编辑/视图…）画在 24 层的整条菜单栏窗口里，拿不到逐项框架；
        // 有辅助功能权限时用 AX 精确量前台应用菜单的最右端，没权限就只信状态项窗口（不比旧行为差）
        if let menuMaxX = appMenuMaxX() {
            if menuMaxX <= notch.minX {
                snapshot.freeLeft = min(snapshot.freeLeft, notch.minX - menuMaxX)
            } else {
                snapshot.freeLeft = 0  // 应用菜单已伸进刘海底下，左翼完全让位
            }
        }

        snapshot.freeLeft = max(0, snapshot.freeLeft)
        snapshot.freeRight = max(0, snapshot.freeRight)
        return snapshot
    }

    /// 前台应用菜单栏最右端（AX，全局左上坐标；不可用返回 nil）
    private static func appMenuMaxX() -> CGFloat? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return nil }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let items = childrenRef as? [AXUIElement] else { return nil }
        var maxX: CGFloat?
        for item in items {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let pos = posRef, let size = sizeRef else { continue }
            var point = CGPoint.zero
            var itemSize = CGSize.zero
            if AXValueGetValue(pos as! AXValue, .cgPoint, &point),
               AXValueGetValue(size as! AXValue, .cgSize, &itemSize) {
                maxX = max(maxX ?? 0, point.x + itemSize.width)
            }
        }
        return maxX
    }
}
