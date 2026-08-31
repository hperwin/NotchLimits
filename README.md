# NotchLimits

A macOS notch companion for Claude usage limits.

Hover under the MacBook notch: it slowly stretches downward, then springs open into a liquid-glass panel that wraps around the notch, showing live Claude rate-limit usage for every account you have. One row per account: the Claude spark, the account name, a big bold percentage for whichever window is closest to the limit, and small bars for each window (5h, 7d, and scoped limits like Fable) with live reset countdowns. Move away and it melts back into the notch.

- **Zero permissions.** No Accessibility, no Screen Recording, no input monitoring. The hover detection is just polled `NSEvent.mouseLocation`.
- **Zero dependencies** in the app itself. Pure SwiftUI + AppKit, no packages, about 1,600 lines of Swift.
- **Interruptible everywhere.** The peek eases toward its build or melt target on timing matched to your dwell (about 0.55s in, faster back out) and retargets the moment you cross the hover boundary; the pop and close are real springs. Idle cost is a 20Hz point-in-rect check with nothing rendered.

## Where the data comes from

NotchLimits renders data from [claude-swap](https://github.com/realiti4/claude-swap) (`cswap`), a third-party CLI that manages multiple Claude accounts and fetches their rate-limit usage. NotchLimits runs `cswap list --json` every 60 seconds and draws the result. It never touches your credentials itself.

Optional: if you run `cswap` on a schedule (cron or launchd) and append its output to `~/Library/Logs/cswap-auto.log`, NotchLimits watches that file and refreshes a couple of seconds after each run instead of waiting for the next 60s poll. Without it the poll alone keeps the panel current.

So the setup is two steps:

```bash
# 1. the data source
uv tool install claude-swap        # or: pipx install claude-swap
cswap add                          # log in your account(s), see the claude-swap docs

# 2. this app
git clone https://github.com/hperwin/NotchLimits.git
cd NotchLimits
Scripts/install.sh                 # builds, ad-hoc signs, installs to /Applications, launches
```

`Scripts/install.sh --launch-agent` also installs a login LaunchAgent so it starts at login.

NotchLimits expects the `cswap` binary at `~/.local/bin/cswap`, which is where `uv tool install` and `pipx` put it. A panel that opens with a header but no account rows means cswap has no accounts configured yet.

## Requirements

- macOS 26 (Tahoe) on Apple silicon. The panel uses the native `glassEffect` liquid glass. (An `.ultraThinMaterial` stand-in exists in the code, but only the headless `--snapshot` renderer uses it, because offscreen rendering cannot sample `glassEffect`.)
- A notch is not strictly required: on a notchless Mac or clamshell mode it falls back to a synthetic band centered at the top of the main screen.
- Xcode (the build uses `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`).
- [claude-swap](https://github.com/realiti4/claude-swap) 0.24+ (`cswap list --json`, schemaVersion 1).

## Try it without hovering

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
.build/debug/NotchLimits --demo-open              # launches straight to the open panel
.build/debug/NotchLimits --snapshot /tmp/nl.png   # headless render of the panel to a PNG, prints SNAPSHOT OK
```

## How the morph works

The whole illusion lives in one always-present, click-through, transparent `NSPanel` pinned to the top of the screen; SwiftUI draws everything.

- **Idle**: nothing rendered, mouse polled at 20Hz.
- **Peek**: cursor enters the hover zone under the notch and a pure-black shape grows out of the notch, driven directly by dwell progress (about 0.55s in, faster back out). It is the notch, seamlessly: no material, no border.
- **Pop**: dwell completes and a spring (response 0.36, damping 0.72) expands the shape into a glass slab that surrounds the notch: the material visibly flows around its left, right, and bottom edges, with a specular hairline tracing the cutout. Black crossfades to glass in the first 120ms; content fades in slightly after the shape lands.
- **Close**: leave the panel and after a short grace period the content fades and the shape springs back into the notch. Re-entering during the grace cancels it.

Panel height derives from the screen and the account list scrolls when it does not fit, so any number of accounts works.

## Built by an agent fleet

This app was written by parallel AI coding agents working from two documents that are kept in the repo as artifacts:

- [`SPEC.md`](SPEC.md): the master build spec. File-by-file stream ownership so agents never collide, shared interfaces spelled out verbatim so independently written streams compile against each other, exact behavioral contracts (hover physics timings, window flags, data mapping), and a machine-verifiable acceptance checklist the integrator runs in order.
- [`DESIGN-V1.1.md`](DESIGN-V1.1.md): the design pass layered on top after v1 integrated green: the notch-wrap glass shape, SF Rounded type, the Claude spark, the big binding-window percentage, and a hard code-budget rule.

If you build software with agent fleets, the shape of these two files (ownership map, verbatim interfaces, acceptance gates, then a separate ruthless design pass) is the transferable part. The current code has evolved past them (v1.2 through v1.5 added pinned-cursor hover fixes, render-server-owned animations, screen-derived panel height with scrolling, and account-name disambiguation), so treat them as the launch spec, not the current state.

## License

MIT.
