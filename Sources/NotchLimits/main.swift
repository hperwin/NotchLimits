import AppKit

// `--demo-open`: launch straight into `.open`, skipping the hover dwell.
// `--snapshot <path>`: headless render of the open panel to a PNG, print
// SNAPSHOT OK/FAIL, exit — no window, no event loop.
// Default: normal hover companion.

let arguments = CommandLine.arguments.dropFirst()
var demoOpen = false
var snapshotPath: String?

var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--demo-open":
        demoOpen = true
    case "--snapshot":
        snapshotPath = iterator.next()
    default:
        break
    }
}

if let snapshotPath {
    let store = UsageStore()
    store.start()
    let ok = await Snapshot.write(store: store, to: snapshotPath)
    print(ok ? "SNAPSHOT OK" : "SNAPSHOT FAIL")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate(demoOpen: demoOpen)
app.delegate = delegate
app.run()
