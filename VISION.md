# VISION.md — Emberfall Kingdom (client)

## Vision
A kingdom-war strategy game Henry himself would happily spend on: deep like Whiteout Survival / Rise of Kingdoms, but **generous by design**. Free tier is a complete game. No dark patterns, no punishment for missed days, no pay-to-win. "Help people first, then convert."

Phase 1: PvE-first iOS client (this repo) + Go kingdom server (sibling repo `emberfall-server`). Phase 2: PvP city attacks, functional shields, alliance wars/territory, rallies, leaderboards, seasons, fog of war, trading.

## Product philosophy
- Fun in 60 seconds: guided build → march → summon onboarding, always skip-able.
- Idle-friendly: while-you-were-away gains, no broken streaks, welcome track never expires.
- Honest stubs: anything phase-2 says so in the UI (shield, server research) instead of pretending.
- One purchase flow per platform: Apple IAP only. No external billing, no web links.

## Conventions for AI tools (shared source of truth)
- **Review branches only.** Never merge to `main` without Henry.
- **No secrets in code.** API keys, certs, and profiles live in the `app-store-release-emberfall` GitHub environment, never in the repo.
- **One purchase flow per platform** (above).
- **Update this file and CHANGELOG.md with every change** (add a dated entry under Changelog).
- **Theme content lives in JSON, never in logic.** New theme variant = new JSON + art + bundle ID + `EmberThemeID`; never a logic fork.
- **Server is authoritative online.** The client never computes resources, timers, or battle outcomes when connected. Display interpolation is cosmetic only.
- **Frozen contract is law.** Deviations are documented in README "Protocol notes" — never silent.
- **Idempotency:** every non-auth mutation carries `Idempotency-Key`; retries reuse the same key.
- `auth/dev` exists only under `#if DEBUG`. Debug-only UI never ships to review builds.
- Monetization pacing: rewarded ads are opt-in; interstitials only on non-gameplay transitions, never mid-build/march/battle; remove-ads is honored everywhere.

## Current state
- 1.0.0 initial client built 2026-09-30, not yet compiled (no Swift toolchain on the Linux build VM — first compile via GitHub macOS runners / Xcode 16+).
- Awaiting Henry: App Store Connect app + 3 IAPs, AdMob app + 2 ad units, provisioning profile (Sign in with Apple), `app-store-release-emberfall` secrets, production server URL, workflow upload via web UI.
- Awaiting server builder: research endpoint for phase-1 online play (client shows an honest notice until then); optional server-side receipt verification.

## Changelog
- 2026-09-30: Initial build — full offline PvE, frozen-contract online client, ThemePack, StoreKit 2 + AdMob, release infra. See CHANGELOG.md.
