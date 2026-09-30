// 用法：swift reserved/verify_menubar.swift
// 转储菜单栏条带内的 layer-25 窗口，检查灵动岛岛体是否压住任何可见状态项。
// 本机 ZCode 无屏幕录制权限，视觉截图不可用，用窗口几何验证（原点为全局左上坐标）。
import AppKit

let primaryHeight = NSScreen.screens.first!.frame.maxY
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var island: CGRect?
var items: [CGRect] = []
for info in list {
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    guard layer == 25 else { continue }
    guard let b = info[kCGWindowBounds as String] as? NSDictionary,
          let f = CGRect(dictionaryRepresentation: b) else { continue }
    guard f.midY <= 44 else { continue }
    let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
    if owner == "灵动岛" && f.height <= 40 { island = f }
    else if owner != "灵动岛" { items.append(f) }
}
guard let i = island else { print("island not found"); exit(1) }
let notchL: CGFloat = 645.5, notchR: CGFloat = 824.5  // 本机刘海位置
let centerOffset = (i.midX - (notchL + notchR) / 2).rounded() * 10 / 10
print("island \(i.minX)...\(i.maxX) w=\(i.width) | 左翼 \(notchL - i.minX)pt 右翼 \(i.maxX - notchR)pt | 中心偏差 \(centerOffset)pt")
var ok = true
for f in items.filter({ $0.width <= 220 && $0.height >= 10 && $0.height <= 44 }).sorted(by: { $0.minX < $1.minX }) {
    let flag = f.intersects(i) ? "  ⚠️ OVERLAP" : ""
    if f.intersects(i) { ok = false }
    print("item \(Int(f.minX))...\(Int(f.maxX)) w=\(Int(f.width))\(flag)")
}
print(ok ? "PASS: 岛体未压住任何可见图标" : "FAIL: 存在重叠")
