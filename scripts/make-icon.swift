import AppKit

// 生成 App 图标：黑色圆角方块 + 白色灵动岛胶囊 + 音符
let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

NSColor.black.setFill()
NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 230, yRadius: 230).fill()

let capsule = NSRect(x: 242, y: 422, width: 540, height: 180)
NSColor.white.setFill()
NSBezierPath(roundedRect: capsule, xRadius: 90, yRadius: 90).fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let note = "♪"
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 130, weight: .bold),
    .foregroundColor: NSColor.black,
    .paragraphStyle: paragraph,
]
let noteSize = (note as NSString).size(withAttributes: attrs)
(note as NSString).draw(
    at: NSPoint(x: capsule.midX - noteSize.width / 2, y: capsule.midY - noteSize.height / 2 - 8),
    withAttributes: attrs
)

image.unlockFocus()

let dir = "Packaging/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for spec in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
             (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
             (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let scaled = NSImage(size: NSSize(width: spec.0, height: spec.0))
    scaled.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: spec.0, height: spec.0))
    scaled.unlockFocus()
    let rep = NSBitmapImageRep(data: scaled.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(spec.1).png"))
}
print("iconset written to \(dir)")
