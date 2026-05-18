import Cocoa

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: \(args[0]) <input.png> <output.png>")
    exit(1)
}

let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

guard let image = NSImage(contentsOf: inputURL) else {
    print("Failed to load image")
    exit(1)
}

let side = min(image.size.width, image.size.height)
// Crop inward by 28% to remove white borders completely
let cropAmount = side * 0.28
let targetSide = side - (cropAmount * 2)

let targetRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let newImage = NSImage(size: targetRect.size)

newImage.lockFocus()

if let ctx = NSGraphicsContext.current {
    ctx.imageInterpolation = .high
    
    // Create a squircle mask (rounded rectangle)
    // macOS Big Sur icon corner radius is roughly 22.5% of the width
    let cornerRadius = 1024.0 * 0.225
    let path = NSBezierPath(roundedRect: targetRect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.addClip()
    
    // The source rect is the cropped area
    let sourceRect = CGRect(x: cropAmount, y: cropAmount, width: targetSide, height: targetSide)
    
    image.draw(in: targetRect, from: sourceRect, operation: .copy, fraction: 1.0)
}

newImage.unlockFocus()

guard let tiffData = newImage.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    print("Failed to create PNG")
    exit(1)
}

try pngData.write(to: outputURL)
print("Saved cropped icon to \(outputURL.path)")
