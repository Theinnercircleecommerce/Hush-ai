import SwiftUI

/// Pixel Berrie. Nearest-neighbour scaling keeps the pixels crisp. Moods
/// without their own PNG yet draw the idle art with a small badge.
struct BerrieView: View {
    @ObservedObject var appState: AppState

    static let size: CGFloat = 96

    var body: some View {
        let mood = BerrieMood.from(hud: appState.hudState, asking: appState.isAsking)
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: Self.image(for: mood))
                    .resizable()
                    .interpolation(.none)
                    .frame(width: Self.size, height: Self.size)
                if Self.artURL(for: mood) == nil, let badge = mood.badgeSymbol {
                    Image(systemName: badge)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.85)))
                        .offset(x: 4, y: -4)
                }
            }
            if case .error(let message) = appState.hudState {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.75, green: 0.15, blue: 0.15)))
            }
        }
        .frame(width: BerrieController.panelSize.width, height: BerrieController.panelSize.height, alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.hudState)
    }

    /// SwiftPM's generated `Bundle.module` fatalErrors when the resource
    /// bundle isn't where it expects, and build.sh puts it in
    /// Contents/Resources. Look there first, then next to the binary (tests).
    private static let resourceBundle: Bundle? = {
        let name = "Hush_Hush.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: BerrieController.self).bundleURL.deletingLastPathComponent(),
        ].compactMap { $0?.appendingPathComponent(name) }
        return candidates.lazy.compactMap { Bundle(url: $0) }.first
    }()

    static func artURL(for mood: BerrieMood) -> URL? {
        resourceBundle?.url(forResource: mood.imageName, withExtension: "png", subdirectory: "Berrie")
    }

    /// 18 pt strawberry for the menu bar. Not a template image — he's red.
    static let menuBarImage: NSImage = {
        let img = (image(for: .idle).copy() as? NSImage) ?? NSImage(size: NSSize(width: 18, height: 18))
        img.size = NSSize(width: 18, height: 18)
        return img
    }()

    private static var cache: [BerrieMood: NSImage] = [:]

    static func image(for mood: BerrieMood) -> NSImage {
        if let cached = cache[mood] { return cached }
        let url = artURL(for: mood) ?? artURL(for: .idle)
        let image = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 1, height: 1))
        cache[mood] = image
        return image
    }
}
