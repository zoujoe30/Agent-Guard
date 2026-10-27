import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconRenderError: Error {
    case invalidArguments
    case contextCreationFailed
    case imageCreationFailed
    case destinationCreationFailed
    case imageWriteFailed
}

private let backgroundColor = CGColor(
    srgbRed: 92.0 / 255.0,
    green: 114.0 / 255.0,
    blue: 149.0 / 255.0,
    alpha: 1.0
)

private let symbolColor = CGColor(
    srgbRed: 238.0 / 255.0,
    green: 241.0 / 255.0,
    blue: 245.0 / 255.0,
    alpha: 1.0
)

private func makeIcon(size: Int) throws -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconRenderError.contextCreationFailed
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / 1024.0, y: CGFloat(size) / 1024.0)

    let background = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
        cornerWidth: 224,
        cornerHeight: 224,
        transform: nil
    )
    context.addPath(background)
    context.setFillColor(backgroundColor)
    context.fillPath()

    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 824))
    shield.addCurve(
        to: CGPoint(x: 316, y: 748),
        control1: CGPoint(x: 451, y: 788),
        control2: CGPoint(x: 381, y: 765)
    )
    shield.addLine(to: CGPoint(x: 316, y: 516))
    shield.addCurve(
        to: CGPoint(x: 512, y: 208),
        control1: CGPoint(x: 316, y: 373),
        control2: CGPoint(x: 394, y: 268)
    )
    shield.addCurve(
        to: CGPoint(x: 708, y: 516),
        control1: CGPoint(x: 630, y: 268),
        control2: CGPoint(x: 708, y: 373)
    )
    shield.addLine(to: CGPoint(x: 708, y: 748))
    shield.addCurve(
        to: CGPoint(x: 512, y: 824),
        control1: CGPoint(x: 643, y: 765),
        control2: CGPoint(x: 573, y: 788)
    )
    shield.closeSubpath()

    context.addPath(shield)
    context.setStrokeColor(symbolColor)
    context.setLineWidth(52)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()

    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: 458, y: 580))
    shackle.addLine(to: CGPoint(x: 458, y: 630))
    shackle.addCurve(
        to: CGPoint(x: 566, y: 630),
        control1: CGPoint(x: 458, y: 700),
        control2: CGPoint(x: 566, y: 700)
    )
    shackle.addLine(to: CGPoint(x: 566, y: 580))

    context.addPath(shackle)
    context.setStrokeColor(symbolColor)
    context.setLineWidth(42)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    let lockBody = CGPath(
        roundedRect: CGRect(x: 430, y: 430, width: 164, height: 168),
        cornerWidth: 30,
        cornerHeight: 30,
        transform: nil
    )
    context.addPath(lockBody)
    context.setFillColor(symbolColor)
    context.fillPath()

    context.setFillColor(backgroundColor)
    context.fillEllipse(in: CGRect(x: 496, y: 502, width: 32, height: 32))
    let keyStem = CGPath(
        roundedRect: CGRect(x: 502, y: 462, width: 20, height: 54),
        cornerWidth: 10,
        cornerHeight: 10,
        transform: nil
    )
    context.addPath(keyStem)
    context.fillPath()

    guard let image = context.makeImage() else {
        throw IconRenderError.imageCreationFailed
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconRenderError.destinationCreationFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconRenderError.imageWriteFailed
    }
}

guard CommandLine.arguments.count == 3 else {
    throw IconRenderError.invalidArguments
}

let masterURL = URL(fileURLWithPath: CommandLine.arguments[1])
let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(
    at: iconsetURL,
    withIntermediateDirectories: true
)

let iconFiles: [(String, Int)] = [
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

try writePNG(makeIcon(size: 1024), to: masterURL)
for (name, size) in iconFiles {
    try writePNG(makeIcon(size: size), to: iconsetURL.appendingPathComponent(name))
}

print(masterURL.path)
print(iconsetURL.path)
