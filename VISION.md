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
- Monetization: zero ads anywhere (no ad SDK). Shop = 3 consumable IAP bundles (speedups, summons, Warden's Cache); free players earn speedups from daily quests and the welcome track.

## Current state
- 1.0.0 initial client built 2026-09-30, not yet compiled (no Swift toolchain on the Linux build VM — first compile via GitHub macOS runners / Xcode 16+).
- Awaiting Henry: App Store Connect app + 3 IAPs (speedup bundle, summon epic10, Warden's Cache), provisioning profile (Sign in with Apple), `app-store-release-emberfall` secrets, production server URL, workflow upload via web UI. No AdMob work needed — the game is ad-free.
- Awaiting server builder: research endpoint for phase-1 online play (client shows an honest notice until then); optional server-side receipt verification.

## Changelog
- 2026-09-30: Ad-free surgery — removed all ads (AdsManager, GMA SPM dep, AdMob placements/IDs, advertising privacy declaration); replaced removeads IAP with Warden's Cache bundle; final 3 consumable IAPs. See CHANGELOG.md.
- 2026-09-30: Initial build — full offline PvE, frozen-contract online client, ThemePack, StoreKit 2 + AdMob, release infra. See CHANGELOG.md.


## September 30, 2026 - Independent source verification

Declared the app-scoped UserDefaults required-reason API (CA92.1), based on the app's actual preferences and local save calls. This does not certify App Store privacy answers or third-party SDK behavior. Final signed archive privacy reports and actual-device/network behavior remain release gates.
Corrected the false zero-collection assertion: the supplied server stores Apple user identifiers, device identifiers, gameplay state, and player chat content. Declared these linked, non-tracking app-functionality categories. Final privacy-policy/legal review and server retention/deletion verification remain outstanding.

Versioned the previously missing release workflow with pinned actions, app-specific identity/environment, manual main-branch signing and upload disabled by default. Removed the incorrect requirement that workflows must stay outside GitHub. Signing environments/secrets, account budget and actual Mac builds remain unverified; nothing dispatched.

Further purchase review found a launch-blocking gap: the client finished consumable transactions and marked them granted while online fulfillment was absent. APIClient never sends lastTransactionId; the server labels receipt verification a future phase. Disabled checkout/product loading and guarded incoming transaction handling before grant/finish. The shop now says purchases are unavailable while free play remains usable. Pending transactions are left unfinished. Durable account-bound fulfillment and sandbox acceptance remain required before enabling purchases; this is containment, not completed billing.

## October 2, 2026 - Review PR #1 merged

- 2026-10-02: PR #1 "fix: prepare native sources and privacy for launch review" merged to main - Launch review prep: native sources, privacy declarations, and official approved icons. Merge commit a6e8bbd58385ab6f44bb0abfa6cf2a4072c810b8.