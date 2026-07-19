# Senti Pocket — Design Direction (forge research, 2026-07-19)

Carter's bar: "the absolute best type of designs… GitHub Mobile or something much better." Research verdict: aim a tier ABOVE GitHub Mobile (solid-native baseline, mixed reviews) at the **Apple Design Award class**: Flighty (ADA winner; the best Live Activities/Dynamic Island integration on the market), Watch Duty (ADA 2025 Social Impact — the closest analog to us: a *trusted real-time alert + briefing* app), Things 3 (calm hierarchy), Fantastical (dense-but-scannable), plus the iOS 26 **Liquid Glass** system language for a current-gen feel.

## 1. North star
Senti Pocket is not a chat app. It is **a call from your team** → **a briefing you can trust** → **a decision you sign**. Three moments, each deserves one signature interaction:
- THE RING — feels like a real incoming call (urgency + delight)
- THE BRIEFING — feels like a security briefing (clarity + trust)
- THE CONFIRM — feels like signing something (weight + irreversibility)

## 2. System (pulse owns; forge verifies on device)
- **Typography**: SF Pro; headline-first. Large Title only on the inbox root; briefing headlines `.title2.bold()`; metadata `.footnote` in secondary. One scale, no custom fonts. Dynamic Type to AX5 (pulse's existing gate).
- **Color**: near-monochrome surfaces; ONE brand accent (Senti green) reserved EXCLUSIVELY for verified/trust states so green literally means "cryptographically verified" everywhere; amber = pending/offline; red = rejected/unverified. Semantic-only color = the trust story told visually.
- **Materials**: cards on `.ultraThinMaterial`; sheets with grabbers; on iOS 26 adopt Liquid Glass (`glassEffect`) behind `#available` so iOS 16 keeps plain materials. Dark-mode-first (demo pops on stage).
- **Motion**: spring-everything (`.snappy` for taps, `.smooth` for transitions); `matchedGeometryEffect` inbox-card → briefing detail; respect Reduce Motion (pulse gate). No linear ease anywhere.
- **Haptics**: `sensoryFeedback` — soft tap on briefing arrive, heartbeat pattern during ring, `.warning` when confirm arms, `.success` when a signed receipt lands. Haptics = the app's voice when the voice is silent.

## 3. Per-screen direction (mapped to OUR screens)
### Incoming call ("Senti is calling")
Full-screen, CallKit-grade: dimmed wallpaper blur, agent-avatar cluster (the agents ARE the callers), app name small, headline preview one line, three pill actions — Answer (accent), Listen Later, Snooze. Subtle breathing ring animation (TimelineView) + heartbeat haptic. **Flighty-move**: a Live Activity + Dynamic Island presence for an incoming/active briefing (even demo-only, it is THE screenshot).
### Briefing inbox
Card list, headline-first; verified chip (green seal) is a FIRST-CLASS element on every card — never decoration; unread = leading accent bar, not a dot. Pull-to-refresh with a tiny Senti glyph. Empty state: one line + one glyph, Things-3 calm, never a blank screen.
### Verified conversation / briefing
Per-agent sections with agent color + monogram avatar; epistemic tags as small-caps chips with semantic tints — [FACT] steel, [INFER] purple, [REC] green — consistent across ALL screens; speaking state = animated waveform bar on the active agent card while TTS plays; barge-in = one oversized mic button pinned bottom (push-to-talk affordance pulse already specs). Evidence refs render as tappable seq-range chips → detail sheet with monospace excerpt + "cited by" backlinks.
### Proposal confirm (THE trust moment — spend the design budget here)
Full-screen sheet. The exact outgoing message inside a distinct "document" card (slightly warmer surface, quote bar); target session + target sequence as labeled rows (never prose); **slide-to-confirm** (not a tap) for the single-use gate — physical weight for an irreversible act; cancel is plain, confirm is deliberate. On post: the receipt card flips in with the signature chip animating from gray → green seal. Offline: the slider itself is replaced by an amber QUEUED — NOT SENT bar (cannot even attempt a fake confirm).
### Offline / pending states
Honest amber everywhere; airplane glyph; PENDING_CONNECTIVITY chip identical in inbox + conversation + receipt views. Never green, never "posted", no spinners pretending progress — a static queued state is more honest than an animated lie.

## 4. Anti-goals
No gradient-wash branding, no custom navigation chrome, no hamburger anything, no skeleton-shimmer overuse, no color used for both brand and trust. Native components first — the ADA class wins by polishing the system language, not replacing it.

## 5. Implementation notes for pulse
NavigationStack + sheets only; `matchedGeometryEffect` for card→detail; `sensoryFeedback` modifiers (iOS 17+, `#available`-gated to keep 16); TimelineView breathing ring; `.contentTransition(.numericText())` for seq counters; Liquid Glass behind `#available(iOS 26)`. Everything deterministic-friendly for the XCUITest scenario matrix (no random animation params). Forge verifies: AX5 Dynamic Type render, Reduce Motion path, dark/light, on sim + physical device, screenshots per screen.

## Sources
- Apple Design Awards 2025 winners/finalists (apple.com newsroom + developer.apple.com/design/awards/2025) — Watch Duty, Speechify, Play, CapWords
- Apple Design Awards 2026 (developer.apple.com/design/awards) — SwiftUI winners with best-in-class Liquid Glass integration
- Flighty ADA + Live Activities/Dynamic Island best-on-market (swiftprogramming.com/best-swiftui-apps)
- iOS 26 Liquid Glass design language (developer trend coverage, 2026)
