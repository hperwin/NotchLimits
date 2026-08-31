# NotchLimits — Design v1.1 — Hayden's calls, Aug 1 2026

> **Historical artifact.** The design pass applied on top of SPEC.md for v1.1.
> Later versions (v1.2 through v1.5) evolved past it; the code is the current truth.
> Kept for the build methodology. See README.md.

**GOAL (Hayden, verbatim intent): a modern notch liquid-glass effect — fluid,
smooth, and optimized.** Concretely: every transition is an interruptible
spring (no fire-and-forget animations, no snapping); the peek scrubs 1:1 with
hover dwell; the pop lands at 60fps with zero visible jank; idle CPU ≈ 0
(20Hz lightweight point-in-rect check, no rendering while idle); while open,
the only recurring work is the once-per-second "updated ago" tick and
once-per-minute countdown refresh. If fluidity and decoration ever conflict,
fluidity wins.

**CODE RULE (Hayden): the shortest amount of code for the most complex tasks.**
Lean on SwiftUI's built-ins (springs, shapes, TimelineView, glassEffect) instead
of custom machinery. When applying this pass, also PRUNE: collapse duplicate
helpers the parallel streams introduced, delete dead code and unused params,
fold single-use abstractions inline. Every line must earn its place. Target:
the whole app well under ~1,200 lines of Swift.

Applies ON TOP of SPEC.md after the v1 build integrates green. Where this file
and SPEC.md conflict, THIS file wins. Interfaces (PanelPhase, HoverEngine,
UsageStore, AccountVM/MeterVM) are unchanged — this is a visual/content pass.

Hayden's directives, verbatim intent:
1. Rounded edges; the open panel extends PAST 150px from the top of the screen.
2. The glass must WARP AROUND THE NOTCH like liquid glass, not hang under it.
3. Fun presentation: rounded text, simple.
4. Claude logos, big percentage, bars easy to understand.

## 1. The notch-wrap shape (replaces the open-state UnevenRoundedRectangle)

New `NotchWrapShape: Shape` (UI/MorphShell.swift or its own file, Stream C
territory). The open panel becomes a single glass slab that SURROUNDS the notch:

- Outer bounds: width = notchWidth + 220 (≈110pt of glass each side), top edge
  at the SCREEN TOP (y=0 in view space), bottom at content height
  (min 320pt tall — must clearly pass 150px — cap 560), corner radii:
  top outer corners 18 (rounded down from screen top), bottom corners 32.
- Interior cutout at top-center: the physical notch band (notchWidth ×
  notchHeight from NotchGeometry) with bottom corner radius 12, so the black
  notch sits INSIDE the glass and the material visibly flows around its left,
  right, and bottom edges. Path = outer rounded rect + `addPath` of the cutout
  with `.evenOdd` fill rule.
- A specular hairline (white 0.14, 1pt stroke) traces the CUTOUT edge only —
  the refraction cue that sells "glass warping around the notch."
  Outer edge keeps the bottom-only white 0.08 hairline from v1.
- glassEffect(.regular.tint(black 0.55)) applied to the whole wrap shape
  (fallback path per SPEC.md). Shadow as v1.
- Menu-bar strip glass: yes, the wrap intentionally overlays the menu bar
  ±110pt around the notch while open. Transient and by design.

Morph continuity: idle and peeking(p) stay EXACTLY v1 (pure-black notch
stretch). The pop spring (0.36/0.72) now expands from the peek silhouette into
NotchWrapShape — animate via a single `openness: Double` 0→1 that lerps outer
width/height/radii AND fades the cutout in (cutout inset lerps from "covers
whole shape top" to the notch rect) so it reads as one liquid motion. Keep the
black→glass crossfade in the first 120ms.

## 2. Typography — SF Rounded everywhere

Every Text gets `.fontDesign(.rounded)`. Weights: semibold for names/header,
bold for the big percentages, medium elsewhere. All numeric text
`.monospacedDigit()`.

## 3. Claude spark logo — native vector, no assets

`ClaudeSpark: Shape` (UI/Ink.swift): the Claude asterisk — 8 rays from center,
each ray a rounded-capsule petal (length r, width 0.42r, corner radius =
half width), rotated at 45° steps, slight taper toward center. Fill coral
`#D97757` (Claude brand coral).

Usage:
- Header: 16pt spark + "Claude Limits" 14pt rounded semibold.
- Each account row leads with a 13pt spark: ACTIVE account = full coral with a
  soft coral glow (shadow coral 0.5, radius 5); inactive = white 0.22.
  The green active dot from v1 is REPLACED by the coral spark treatment.
  Active row also gets a faint coral 0.08 row-background capsule.

## 4. Row layout — simple, glanceable (replaces v1 row spec)

Row height ≈ 64, hairline separators stay.

```
[spark] name-rounded-13-semibold                    [BIG %  17pt bold]
        5h ▍▬▬▬▬▬▬ 46%   7d ▬▬▬▬ 27%   Fable ▬▬▬ 46%
        └ smallest-countdown line, 9pt muted (e.g. "5h resets in 2h 58m")
```

- BIG % = the account's BINDING window (max pct across meters), colored by its
  severity (normal = white primary; warning/serious/critical = status color)
  with the window's label ("7d") in 9pt muted right under it — color never
  alone. 100% renders as "FULL" 15pt bold in critical.
- Bars: capsule track white 0.12, 56 × 5pt, fill severity color (normal white
  0.55), tiny pct 10pt rounded next to each. Labels 9pt muted.
- relogin_required: spark goes white 0.22 + row shows
  exclamationmark.triangle.fill + "relogin needed" 10pt critical instead of the
  bars' countdown line; keep last-good bars visible.
- Drop the org-name line entirely (simplicity directive). displayName stays
  alias ?? email local-part.

## 5. Acceptance additions (rerun after applying)

- Snapshot PNG: panel ≥ 320pt tall content, wrap shape visible (glass columns
  left+right of a notch-shaped void at top-center), rounded font evident.
- All v1 acceptance items still pass (build, snapshot, demo-open bounds, CPU,
  bundle).
