import Cocoa

let imagePath = "/Users/jbeeren/.gemini/antigravity/brain/b2063cb6-91c3-4999-9c89-03f320e485ad/media__1778754336489.jpg"
guard let image = NSImage(contentsOfFile: imagePath) else {
    print("Could not load image")
    exit(1)
}

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData) else {
    print("Could not get bitmap")
    exit(1)
}

// Convert to single color template (black shapes, transparent background)
let width = bitmap.pixelsWide
let height = bitmap.pixelsHigh
let newBitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: width * 4,
    bitsPerPixel: 32
)!

for y in 0..<height {
    for x in 0..<width {
        let color = bitmap.colorAt(x: x, y: y)!
        // Identify orange (high red, low blue)
        if color.redComponent > 0.5 && color.blueComponent < 0.3 {
            newBitmap.setColor(NSColor.black, atX: x, y: y)
        } else {
            newBitmap.setColor(NSColor.clear, atX: x, y: y)
        }
    }
}

let finalImage = NSImage(size: NSSize(width: width, height: height))
finalImage.addRepresentation(newBitmap)

// Save 2x version (e.g., 36x36 height)
func saveResized(image: NSImage, targetHeight: CGFloat, filename: String) {
    let ratio = targetHeight / CGFloat(height)
    let targetWidth = CGFloat(width) * ratio
    let targetSize = NSSize(width: targetWidth, height: targetHeight)
    
    let resizedImage = NSImage(size: targetSize)
    resizedImage.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: targetSize))
    resizedImage.unlockFocus()
    
    guard let tiff = resizedImage.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let pngData = rep.representation(using: .png, properties: [:]) else { return }
    try? pngData.write(to: URL(fileURLWithPath: filename))
}

// Menu bar icon usually needs 18pt height. 
// So @1x = 18px, @2x = 36px, @3x = 54px
saveResized(image: finalImage, targetHeight: 18, filename: "MenuBarIcon.png")
saveResized(image: finalImage, targetHeight: 36, filename: "MenuBarIcon@2x.png")
saveResized(image: finalImage, targetHeight: 54, filename: "MenuBarIcon@3x.png")

print("Generated!")
