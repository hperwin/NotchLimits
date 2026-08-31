import AppKit
import SwiftUI

/// The single, always-present window. Borderless and non-activating so it
/// never steals focus from whatever app is frontmost; its frame never
/// moves or resizes after creation — only the SwiftUI content inside
/// morphs. Click-through in `.idle`/`.peeking`, interactive in `.open`
/// (toggled by AppDelegate as it observes `engine.phase`).
@MainActor
final class HostWindow: NSPanel {
    private let engine: HoverEngine

    /// Fixed panel width: generous enough to contain the open shape
    /// (notchWidth + 220) plus room for its drop shadow to blur into.
    /// Height is derived per-screen at init from the geometry's
    /// maxOpenPanelHeight, so the window never caps the account list.
    static let panelWidth: CGFloat = 480

    /// Size of the open panel shape, pushed by MorphShell whenever its open
    /// target changes. `openPanelRect` gives HoverEngine the REAL panel rect
    /// for its stay-open hit test — the window is taller than a typical
    /// panel, so the raw frame would hold the panel open with the cursor
    /// far below it.
    private var openPanelSize: CGSize = .zero

    var openPanelRect: NSRect {
        guard openPanelSize != .zero else { return frame }
        return NSRect(
            x: frame.midX - openPanelSize.width / 2,
            y: frame.maxY - openPanelSize.height,
            width: openPanelSize.width,
            height: openPanelSize.height
        )
    }

    init(geometry: NotchGeometry, engine: HoverEngine, store: UsageStore, onQuit: @escaping () -> Void) {
        self.engine = engine

        let size = NSSize(
            width: HostWindow.panelWidth,
            height: geometry.maxOpenPanelHeight + geometry.notchRect.height + 40
        )
        let origin = NSPoint(
            x: geometry.panelAnchorX - size.width / 2,
            y: geometry.screen.frame.maxY - size.height
        )
        let frame = NSRect(origin: origin, size: size)

        // NSWindow's true designated initializer omits `screen:` — that
        // variant is a convenience initializer, and calling it via
        // `super.init` from a subclass crashes at runtime ("unimplemented
        // initializer") because the designated one is never overridden.
        // `frame` is already in absolute global coordinates (derived from
        // `geometry.screen.frame`), so AppKit places it on the right
        // display without needing the screen parameter.
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        // `isFloatingPanel`'s setter internally reassigns the window's raw
        // CGWindowLevel to NSWindow.Level.floating (3) as a side effect —
        // setting it clobbers a `.level` assigned earlier. The spec calls
        // for `.statusBar` (25), so it must be (re-)applied last to win.
        level = .statusBar

        let hosting = NSHostingView(rootView: MorphShell(
            engine: engine, store: store, onQuit: onQuit,
            onOpenPanelSize: { [weak self] size in self?.openPanelSize = size }
        ))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        contentView = hosting
    }

    // Borderless windows default to `canBecomeKey == false`; override so
    // the panel can take key status (for Esc / scroll / click) while open,
    // without ever activating the owning app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // AppKit silently pushes any window's requested frame down so its top
    // edge never overlaps the menu bar — even for borderless panels above
    // `.mainMenu` level. That breaks "top flush with screen top" (the whole
    // point is drawing fused with the notch), so this window's fixed frame
    // must be exempted from that constraint entirely.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        engine.requestClose()
    }
}
