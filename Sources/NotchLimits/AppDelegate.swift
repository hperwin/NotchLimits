import AppKit
import Combine

/// Wires the whole app together: geometry → store → engine → window, then
/// observes `engine.phase` to gate the window's mouse pass-through and key
/// status. `.accessory` activation policy — no Dock icon, no menu bar; this
/// is a background notch companion only.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demoOpen: Bool

    private var store: UsageStore!
    private var engine: HoverEngine!
    private var window: HostWindow!
    private var phaseObserver: AnyCancellable?

    init(demoOpen: Bool) {
        self.demoOpen = demoOpen
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        guard let geometry = NotchGeometry.detect() else {
            // NotchGeometry.detect() only fails if there are no screens at
            // all (no NSScreen.main) — nothing useful to run without one.
            fatalError("NotchGeometry.detect() found no screens")
        }

        let store = UsageStore()
        let engine = HoverEngine(geometry: geometry)
        let window = HostWindow(
            geometry: geometry,
            engine: engine,
            store: store,
            onQuit: { NSApplication.shared.terminate(nil) }
        )

        self.store = store
        self.engine = engine
        self.window = window

        engine.panelFrameProvider = { [weak window] in window?.openPanelRect }

        // The window is always ordered front (per spec); only its content's
        // click-through-ness and key status change with phase.
        phaseObserver = engine.$phase.sink { [weak window, weak store] phase in
            guard let window else { return }
            switch phase {
            case .idle, .peeking:
                window.ignoresMouseEvents = true
                if window.isKeyWindow {
                    window.resignKey()
                }
            case .open:
                window.ignoresMouseEvents = false
                window.makeKey()
                // The 60s poll can leave the panel a minute stale at the
                // moment it opens; kick a fetch so the numbers you're
                // looking at are always seconds old.
                store?.refreshNow()
            }
        }

        window.orderFrontRegardless()

        store.start()
        engine.start()

        if demoOpen {
            engine.forceOpen()
            // CGWindowListCopyWindowInfo reports 0×0 for this transparent,
            // borderless panel, so --demo-open verification reads the real
            // frame straight from the window instead.
            let f = window.frame
            print("WINDOW_FRAME x=\(f.origin.x) y=\(f.origin.y) w=\(f.width) h=\(f.height) midX=\(f.midX) screenMidX=\(geometry.screen.frame.midX) screenTopY=\(geometry.screen.frame.maxY)")
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
