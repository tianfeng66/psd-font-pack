// 生成 App 图标：渐变圆角底 + 白色「Aa」+ 下方的压缩包托盘
import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = size
    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let body = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.62, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.86, alpha: 1),
    ])!.draw(in: body, angle: -90)

    // 「Aa」
    let font = NSFont.systemFont(ofSize: s * 0.40, weight: .heavy)
    let text = NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: NSColor.white])
    let ts = text.size()
    text.draw(at: NSPoint(x: (s - ts.width) / 2, y: s * 0.40))

    // 托盘：圆角矩形底 + 中间缺口，示意「打包」
    NSColor.white.setFill()
    let trayW = s * 0.50, trayH = s * 0.13
    let trayX = (s - trayW) / 2, trayY = s * 0.20
    NSBezierPath(roundedRect: NSRect(x: trayX, y: trayY, width: trayW, height: trayH),
                 xRadius: s * 0.03, yRadius: s * 0.03).fill()
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    NSBezierPath(roundedRect: NSRect(x: s / 2 - s * 0.07, y: trayY + trayH * 0.45, width: s * 0.14, height: trayH),
                 xRadius: s * 0.02, yRadius: s * 0.02).fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(size: CGFloat) -> Data {
    let rep = drawIcon(size: size)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

/// 直接拼 .icns：magic + 长度 + 若干 (类型, 长度, PNG 数据) 块，省得依赖 iconutil
func makeICNS() -> Data {
    let chunks: [(String, CGFloat)] = [
        ("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128),
        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
    ]
    var cache: [CGFloat: Data] = [:]
    var body = Data()
    for (type, size) in chunks {
        let payload = cache[size] ?? png(size: size)
        cache[size] = payload
        guard !payload.isEmpty else { continue }
        body.append(contentsOf: Array(type.utf8))
        var length = UInt32(payload.count + 8).bigEndian
        withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
        body.append(payload)
    }
    var out = Data("icns".utf8)
    var total = UInt32(body.count + 8).bigEndian
    withUnsafeBytes(of: &total) { out.append(contentsOf: $0) }
    out.append(body)
    return out
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.icns"
try makeICNS().write(to: URL(fileURLWithPath: outPath))
if CommandLine.arguments.count > 2 {
    try png(size: 512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("icon written to \(outPath)")
