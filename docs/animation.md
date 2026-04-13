---
title: Slash Animation
description: State machine, timing, and rendering details for the menu bar slash traffic animation.
---

The diagonal slash between the 5-hour and weekly utilization numbers in the menu bar icon doubles as a traffic indicator. When the local proxy forwards a request, the slash morphs from a static gray line into a glowing orange segment that bounces back and forth, then settles back to gray when traffic stops.

# State machine

The animation is driven by a five-state machine in `StatusBarController`:

```
         traffic event
  idle ───────────────► starting
   ▲                       │
   │                       │ morph reaches 1.0
   │ morph reaches 0.0     ▼
stopping ◄──────────── bouncing ◄─┐
   ▲        at center      │     │ traffic event
   │                       │     │
   │        timer expires  ▼     │
   └────────────────── waitingForCenter
        at center
```

| State | What happens | Exit condition |
|-------|-------------|----------------|
| `idle` | Full-width gray slash, timer stopped | Traffic event arrives |
| `starting` | Slash shrinks toward a short glowing segment (morph 0 -> 1) | Morph reaches 1.0 |
| `bouncing` | Glowing segment ping-pongs along the slash; 2s countdown timer | Timer expires, or traffic event resets it |
| `waitingForCenter` | Segment coasts toward the center position | Segment reaches center (within epsilon) |
| `stopping` | Segment expands back to full-width gray (morph 1 -> 0) | Morph reaches 0.0 |

A traffic event arriving mid-animation re-triggers appropriately: during `bouncing` it resets the countdown, during `waitingForCenter` it jumps back to `bouncing`, during `stopping` it reverses to `starting`.

# SlashAnimation struct

Passed from `StatusBarController` to `BarIconRenderer.drawSlash()` each frame:

```swift
struct SlashAnimation {
    let flow: SlashFlow       // .idle | .upstream | .downstream
    let phase: CGFloat        // [0, 2) — ping-pong position along the slash
    let transition: CGFloat   // 0 = idle (full-width gray), 1 = active (short glowing segment)
}
```

`phase` is converted to a ping-pong value in [0, 1] via `raw <= 1 ? raw : 2 - raw`, so 0 -> 1 -> 0 maps to one full back-and-forth cycle.

# Timing

All values tuned for 30 fps (timer interval = 1/30s):

| Constant | Value | Effect |
|----------|-------|--------|
| `morphSpeed` | 0.083 | Morph increment per tick; full morph in ~12 ticks (~0.4s) |
| `phaseStep` | 0.04 | Phase increment per tick; full ping-pong in ~50 ticks (~1.7s) |
| `bounceDuration` | 2.0s | Bounce countdown before coasting to center |
| `centerEpsilon` | 0.05 | Snap-to-center threshold |

# Rendering

The slash runs from upper-right to lower-left between the two number cells.

**Segment geometry** — the visible portion of the slash is computed from `phase` and `transition`:

```
halfRunner = 0.25              (runner is 50% of slash length, halved)
center     = 0.5 + transition * (pingPong - 0.5)
halfWidth  = 0.5 - transition * (0.5 - halfRunner)
segStart   = clamp(center - halfWidth, 0, 1)
segEnd     = clamp(center + halfWidth, 0, 1)
```

When `transition = 0` (idle), the full slash is drawn. When `transition = 1` (active), a 50%-length segment is drawn at the `pingPong` position.

**Colors** — the core line color blends from `secondaryLabelColor` (gray) to `systemOrange` proportional to `transition`, using sRGB interpolation.

**Glow** — when `transition > 0.01`, a second wider stroke is drawn underneath with:
- Shadow: blur 2.5pt, orange at 60% opacity * transition
- Stroke: orange at 50% opacity * transition
- Width: `1.0 + 1.5 * transition`

The core line narrows from 1.5pt (idle) to 1.0pt (active) as the glow takes over.

# Key files

- `Rendering/BarIconRenderer.swift` — `SlashFlow`, `SlashAnimation`, `drawSlash()`, color blending
- `App/StatusBarController.swift` — `AnimationState` enum, 30fps timer, `trafficEventReceived()`, `onAnimationTick()`
