import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Headless renderer used by `--snapshot <path>`: draws the open-state wrap
/// panel + PanelContent at 2x to a PNG. `ImageRenderer` has no live window
/// behind it, so `glassEffect` rasterizes as a no-op there — this path
/// forces `NotchWrapPanel`'s material fallback and paints a synthetic dark
/// backdrop behind everything so the PNG is faithful evidence of the
/// design. The live app always uses the real `glassEffect`.
@MainActor
enum Snapshot {
    private static let minOpenHeight: CGFloat = 320

    static func write(store: UsageStore, to path: String) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while store.lastUpdated == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let geometry = NotchGeometry.detect()
        let notchWidth = geometry?.notchRect.width ?? 200
        let notchHeight = geometry?.notchRect.height ?? 32
        let openWidth = notchWidth + 220

        let content = PanelContent(store: store, onQuit: {}, width: openWidth, notchHeight: notchHeight)
            .fixedSize(horizontal: false, vertical: true)
        let maxOpenHeight = geometry?.maxOpenPanelHeight ?? 560
        let panelHeight = min(max(measuredHeight(of: content), minOpenHeight + notchHeight), maxOpenHeight + notchHeight)

        let scene = ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.04)],
                startPoint: .top, endPoint: .bottom
            )
            NotchWrapPanel(
                morph: 1, notchWidth: notchWidth, notchHeight: notchHeight,
                glassAmount: 1, borderOpacity: 1, forceGlassFallback: true
            )
            .frame(width: openWidth, height: panelHeight, alignment: .top)
            content
                .frame(height: panelHeight, alignment: .top)
                .clipped()
        }
        .frame(width: openWidth + 48, height: panelHeight + 48)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2.0
        renderer.isOpaque = true

        guard let cgImage = renderer.cgImage else { return false }
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Renders `content` once at scale 1, offscreen, purely to measure its
    /// natural height before composing the real (sized, backdropped) scene.
    private static func measuredHeight(of content: some View) -> CGFloat {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1.0
        return renderer.cgImage.map { CGFloat($0.height) } ?? minOpenHeight
    }
}
