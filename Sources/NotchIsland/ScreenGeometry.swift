import AppKit

struct ScreenGeometry {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool
}

enum NotchLocator {
    /// 优先找带刘海的内建屏幕；没有则回退到主屏顶部中央的"虚拟岛"
    static func best() -> ScreenGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea ?? .zero
            let right = screen.auxiliaryTopRightArea ?? .zero
            let gap = right.minX - left.maxX
            let width = gap > 1 ? gap : 179
            return ScreenGeometry(
                screen: screen,
                notchWidth: width,
                notchHeight: screen.safeAreaInsets.top,
                hasNotch: true
            )
        }
        guard let main = NSScreen.main else { return nil }
        return ScreenGeometry(screen: main, notchWidth: 150, notchHeight: 30, hasNotch: false)
    }
}
