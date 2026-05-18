import Cocoa

let width: CGFloat = 36
let height: CGFloat = 36

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

let context = NSGraphicsContext.current!.cgContext
context.setFillColor(NSColor.black.cgColor)

// 5 vertical rounded rectangles
let barWidth: CGFloat = 4
let spacing: CGFloat = 3
let heights: [CGFloat] = [12, 22, 32, 22, 12]

let totalWidth = (barWidth * 5) + (spacing * 4)
let startX = (width - totalWidth) / 2.0

for (index, barHeight) in heights.enumerated() {
    let x = startX + CGFloat(index) * (barWidth + spacing)
    let y = (height - barHeight) / 2.0
    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
    let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
    context.addPath(path)
}

context.fillPath()
image.unlockFocus()
image.isTemplate = true

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let pngData = rep.representation(using: .png, properties: [:]) else {
    print("Failed")
    exit(1)
}

try? pngData.write(to: URL(fileURLWithPath: "/Users/jbeeren/AI files/Hush-ai/Sources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png"))
print("Done!")
