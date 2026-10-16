# NotchLimits

A macOS notch companion for Claude usage limits.

Hover under the MacBook notch: it slowly stretches downward, then springs open into a liquid-glass panel that wraps around the notch, showing live Claude rate-limit usage for every account you have. Across the top, right under the notch, is one number: the Claude Code and Codex tokens this Mac has spent, rolling up live on an odometer. One row per account: the Claude spark, the account name, a big bold percentage for whichever window is closest to the limit, and small bars for each window (5h, 7d, and scoped limits like Fable) with live reset countdowns. Move away and it melts back into the notch.

- **Zero permissions.** No Accessibility, no Screen Recording, no input monitoring. The hover detection is just polled `NSEvent.mouseLocation`.
- **Zero dependencies** in the app itself. Pure SwiftUI + AppKit, no packages, about 3,000 lines of Swift.
- **Interruptible everywhere.** The peek eases toward its build or melt target on timing matched to your dwell (about 0.55s in, faster back out) and retargets the moment you cross the hover boundary; the pop and close are real springs. Idle cost is a 20Hz point-in-rect check with nothing rendered.

## Where the data comes from

NotchLimits renders data from [claude-swap](https://github.com/realiti4/claude-swap) (`cswap`), a third-party CLI that manages multiple Claude accounts and fetches their rate-limit usage. NotchLimits runs `cswap list --json` every 60 seconds and draws the result. It never touches your credentials itself.

Optional: if you run `cswap` on a schedule (cron or launchd) and append its output to `~/Library/Logs/cswap-auto.log`, NotchLimits watches that file and refreshes a couple of seconds after each run instead of waiting for the next 60s poll. Without it the poll alone keeps the panel current.

### Optional: a Codex row

If you also use OpenAI's Codex CLI, [`Scripts/nl-usage`](Scripts/nl-usage) is an opt-in shim that adds a `codex` row to the panel. It runs `cswap list --json` and reads Codex's rate limits over `codex app-server` JSON-RPC (`account/rateLimits/read`) in parallel, then emits one merged document in cswap's wire schema with Codex as account slot 99. Codex handles its own token refresh, and the shim (Python stdlib only, no dependencies) never touches credentials. To opt in:

```bash
ln -s "$PWD/Scripts/nl-usage" ~/.local/bin/nl-usage
```

NotchLimits prefers `~/.local/bin/nl-usage` when it exists and behaves exactly as before when it doesn't. If a Codex read fails, the shim reuses its last snapshot for up to 30 minutes (shown as a stale row) or omits the row; cswap errors pass through untouched.

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

## Token counter

The number at the top of the panel counts the Claude Code and Codex tokens used on this Mac, across every account and profile: input, output, cache writes and cache reads. It needs no setup and no account access; it reads the session logs both tools already write locally:

- **Claude Code**: `~/.claude/projects`, `$CLAUDE_CONFIG_DIR/projects`, `~/.config/claude/projects`, any other `~/.claude-*` config dir, claude-swap's per-account profiles, Xcode's Claude agent, and Claude desktop's local agent sessions. Each API response is counted once, at its final usage.
- **Codex**: `~/.codex/sessions` and `~/.codex/archived_sessions` (or `$CODEX_HOME`). Forked sessions replaying their parent's history are not counted twice.

`$CLAUDE_CONFIG_DIR` and `$CODEX_HOME` are honored when they are set in the app's own environment (for example with `launchctl setenv`); the app does not read your shell's rc files.

Nothing leaves your Mac, and the number only ever goes up. The first launch counts what is still on disk, in the background (the caption says "counting" until it is done). Claude Code deletes transcripts after about 30 days by default, so history older than that is not in the total. From then on nothing is lost: a ledger in `~/Library/Application Support/NotchLimits` remembers how far into each log it has read and what that log was worth, so a relaunch reads only new lines and pruned transcripts stay counted. The app follows each log as it is written, whether or not the panel is open, and costs next to nothing when no tokens are moving.

```bash
.build/debug/NotchLimits --tokens    # count once and print the totals and per-log offsets as JSON
```

Set `NOTCHLIMITS_STATE_DIR` to keep a dev build's ledger apart from the installed app's.

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
.build/debug/NotchLimits --demo-open --pin-open   # ...and keeps it open with no cursor on it
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
