# Motion

Original design language — near-black surfaces, a single warm signal colour
(`#FF6A3D`) and a soft aura gradient. Inspired by the *feel* of modern AI
chat apps (calm, fast, physical); no third-party branding or assets.

All motion goes through `MotionKit.swift`: every token (`smooth`, `bouncy`,
`drag`, `micro`) has a Reduce Motion variant (crossfade or none), staggers are
capped, and a unit test enforces that every token has a reduced variant.

**Motion Lab** (Settings → Developer; in release builds triple-tap the orb in
About) plays every moment below on demand with sample data, and has a
“Simulate Reduce Motion” toggle — so you can review it on the phone without a
Mac.

## Shipped

| Moment | Where |
|---|---|
| Launch: mascot fades/scales up, tagline types out (< 1.2 s, tap to skip) | first launch / Motion Lab |
| Living mascots (orb, squircle, triangle, hexagon, pill, diamond) with mood-driven idle: idle, thinking, working, waiting for you, done, failed, offline; hop on selection | Team, Chat header, Tasks |
| Team constellation hero + matched-geometry teammate pill | Team, Chat |
| Streaming text with caret | Chat |
| Tool card aura border while running; shake on failure | Chat, Motion Lab |
| Approval sheet with amber pulse border; **hold-to-confirm** for widening scopes | global sheet, inline card |
| “Connected” pulse rings + capability checklist reveal | Settings → Hermes → Test |
| Depth orbit of sources (iOS, Telegram, VPS, cron) | Motion Lab |
| Live indicator (connected / reconnecting countdown / failed) | Chat, Settings |
| Run timeline dots, run state icons, tab badges, selection haptics | Tasks, tab bar |

## Deferred (honestly not built yet)

- Voice mode with a MeshGradient aura (no voice input in this build).
- iOS 18 zoom navigation transitions (app targets iOS 17; would need availability gating).
- Per-token blur-in reveal for streaming text (currently a simpler fade + caret).
- On-device frame-drop / hitch overlay for performance review.
