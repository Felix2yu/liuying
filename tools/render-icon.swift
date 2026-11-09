// 生成流影的 .icns。
//
// 用法：
//   swiftc -O tools/render-icon.swift -o /tmp/render-icon
//   /tmp/render-icon .build/liuying.iconset
//   iconutil -c icns .build/liuying.iconset -o Resources/liuying.icns
//
// 为什么用 CoreGraphics 而不是 ImageMagick / SVG 转换：本机实测 ImageMagick
// 处理渐变和描边时会静默出错，而 CG 画出来的就是最终像素。
//
// 设计：深靛→紫的圆角方块（暗色播放器），一条流动的波浪（「流」），
// 中间白色播放三角（「影」）。

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let iconsetNames: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let design: CGFloat = 1024
let inset: CGFloat = 64
let contentRect = CGRect(x: inset, y: inset, width: design - inset * 2, height: design - inset * 2)
let cornerRadius: CGFloat = 210

func makeContext(pixels: Int) -> CGContext? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let scale = CGFloat(pixels) / design
    context.scaleBy(x: scale, y: scale)
    // 翻转成「左上角为原点、y 向下」，画图时更直观。
    context.translateBy(x: 0, y: design)
    context.scaleBy(x: 1, y: -1)
    return context
}

func draw() -> CGContext? {
    guard let context = makeContext(pixels: Int(design)) else { return nil }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    let squircle = CGPath(
        roundedRect: contentRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    )

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    // 底色：深靛 → 紫
    let backgroundColors = [
        CGColor(red: 0.07, green: 0.08, blue: 0.18, alpha: 1),
        CGColor(red: 0.22, green: 0.11, blue: 0.42, alpha: 1),
        CGColor(red: 0.36, green: 0.16, blue: 0.52, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: backgroundColors, locations: [0, 0.55, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 120, y: 0),
            end: CGPoint(x: 900, y: design),
            options: []
        )
    }

    // 左上角柔光
    let glowColors = [
        CGColor(red: 0.55, green: 0.65, blue: 1.0, alpha: 0.28),
        CGColor(red: 0.55, green: 0.65, blue: 1.0, alpha: 0.0),
    ] as CFArray
    if let glow = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1]) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: 300, y: 240), startRadius: 0,
            endCenter: CGPoint(x: 300, y: 240), endRadius: 520,
            options: []
        )
    }

    // 流动的波浪：三条错开的贝塞尔曲线，越靠下越淡
    let waves: [(y: CGFloat, amplitude: CGFloat, alpha: CGFloat, width: CGFloat)] = [
        (735, 46, 0.55, 20),
        (800, 34, 0.34, 14),
        (862, 24, 0.20, 10),
    ]
    for wave in waves {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -40, y: wave.y))
        path.addCurve(
            to: CGPoint(x: 512, y: wave.y - 8),
            control1: CGPoint(x: 150, y: wave.y - wave.amplitude * 2),
            control2: CGPoint(x: 360, y: wave.y + wave.amplitude * 1.6)
        )
        path.addCurve(
            to: CGPoint(x: 1080, y: wave.y - 20),
            control1: CGPoint(x: 690, y: wave.y - wave.amplitude * 2.2),
            control2: CGPoint(x: 900, y: wave.y + wave.amplitude * 1.2)
        )
        context.addPath(path)
        context.setStrokeColor(CGColor(red: 0.62, green: 0.85, blue: 1.0, alpha: wave.alpha))
        context.setLineWidth(wave.width)
        context.setLineCap(.round)
        context.strokePath()
    }

    // 播放三角：先填，再用同色 round-join 描边把尖角磨圆
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: 408, y: 336))
    triangle.addLine(to: CGPoint(x: 408, y: 604))
    triangle.addLine(to: CGPoint(x: 664, y: 470))
    triangle.closeSubpath()

    context.setShadow(
        offset: CGSize(width: 0, height: 18),
        blur: 48,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
    )
    context.addPath(triangle)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.98))
    context.fillPath()

    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.addPath(triangle)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.98))
    context.setLineWidth(44)
    context.setLineJoin(.round)
    context.strokePath()

    context.restoreGState()

    // 一圈很淡的内描边，让图标在浅色背景上也有轮廓
    context.addPath(squircle)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    context.setLineWidth(6)
    context.strokePath()

    return context
}

// MARK: - 输出

guard CommandLine.arguments.count >= 2 else {
    print("用法：render-icon <输出目录>")
    exit(1)
}
let outputDirectory = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

// 先在高分辨率上画一次，再逐级缩小 —— 比每个尺寸重画更平滑。
guard let master = draw(), let masterImage = master.makeImage() else {
    print("绘制失败")
    exit(1)
}

for entry in iconsetNames {
    guard let context = makeContext(pixels: entry.pixels) else { continue }
    context.interpolationQuality = .high
    context.draw(masterImage, in: CGRect(x: 0, y: 0, width: design, height: design))
    guard let image = context.makeImage() else { continue }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(entry.name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { continue }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("  \(entry.name)  \(entry.pixels)px")
}

print("完成：\(outputDirectory)")
