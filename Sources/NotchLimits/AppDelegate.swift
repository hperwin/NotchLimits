import AppKit
import Combine

/// Wires the whole app together: geometry → stores → engine → window, then
/// observes `engine.phase` to gate the window's mouse pass-through and key
/// status. `.accessory` activation policy — no Dock icon, no menu bar; this
/// is a background notch companion only.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demoOpen: Bool
    private let pinOpen: Bool

    private var store: UsageStore!
    private var tokens: TokenStore!
    private var engine: HoverEngine!
    private var window: HostWindow!
    private var phaseObserver: AnyCancellable?

    init(demoOpen: Bool, pinOpen: Bool) {
        self.demoOpen = demoOpen
        self.pinOpen = pinOpen
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
        let tokens = TokenStore()
        let engine = HoverEngine(geometry: geometry)
        let window = HostWindow(
            geometry: geometry,
            engine: engine,
            store: store,
            tokens: tokens,
            onQuit: { NSApplication.shared.terminate(nil) }
        )

        self.store = store
        self.tokens = tokens
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
        // Counts whether or not the panel is open, so the total is already
        // current, and the first run's backfill long done, when you look.
        tokens.start()
        engine.pinnedOpen = pinOpen
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

    /// Autosave runs at most every 10 s; this keeps the last few seconds.
    func applicationWillTerminate(_ notification: Notification) {
        guard let tokens else { return }
        // The X quits with the hero up, so no roll settles or unmounts to
        // record what it showed. It never draws above the total, so the next
        // open starts at or above anything already seen.
        if engine.phase == .open, tokens.total > tokens.lastShown ?? 0 { tokens.lastShown = tokens.total }
        tokens.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
