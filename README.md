# Emberfall Kingdom

A native iOS kingdom-war strategy game (SwiftUI + SpriteKit), built the way Henry wants games built: **free tier genuinely useful, no dark patterns, fun in 60 seconds.**

**Theme #1: Ember** — raise the last ember-citadel against the Frost.
Phase 1 is PvE-first: city building, troops, research, a frost-node world map, marches, battle reports, commander summoning with visible pity, daily quests, and a 7-day welcome track. PvP, shields, and alliances are phase 2.

- Bundle ID: `app.emberfall.game`
- Target: iOS 17+, portrait, iPhone
- Server: authoritative online play against Henry's kingdom server (see `~/workspace/emberfall-kingdom/SERVER_DESIGN.md`); **full offline PvE game** with no sign-in.

## Architecture

```
Emberfall/
  EmberfallApp.swift          — entry: Ads warm-up, StoreKit product load, session restore
  Theme/ThemePack.swift        — data-driven theme (all names, palette, copy live in JSON)
  Theme/Themes/emberfall.json  — theme #1 content pack
  Config/offline_config.json   — offline tuning (costs, timers, troop stats, pity, starter state)
  Net/
    Models.swift               — frozen REST/WS contract models
    APIClient.swift            — REST client (bearer JWT, idempotency keys, 401 refresh retry)
    WSClient.swift             — /v1/ws WebSocket (deltas, reports, notifications, auto-reconnect)
    KeychainHelper.swift       — refresh-token storage
    LocalSim.swift             — complete offline PvE simulation (persistent, idle gains)
  Game/
    GameState.swift            — single source of truth; offline ⇄ online mode bridge
    CityScene.swift            — SpriteKit 8×8 city grid (theme-colored, knows no theme names)
    StoreManager.swift         — StoreKit 2 (verified-only purchases, restore, refund handling)
    AdsManager.swift           — AdMob rewarded + interstitial (generous pacing)
    Haptics.swift / SoundManager.swift — juice (synthesized SFX, no audio assets)
  Views/                       — City, Wilds, Wardens, Quests, Settings, Onboarding
```

**The client is a dumb terminal online.** It never computes resources, timers, or battle outcomes when connected — it renders server state and sends intents. All display interpolation is cosmetic. The offline sim is a separate, complete game.

**Variant #2 = new JSON + art + bundle ID, never a fork.** Every theme-specific string, color, building name, troop name, commander pool, enemy identity, and line of tutorial/quest/away-screen copy lives in `Theme/Themes/<id>.json`. Game logic only sees theme-agnostic keys (`citadel`, `infantry`, `tier2_arms`). See "Adding theme variant #2" below.

## Offline vs server-required features

| Feature | Offline (no sign-in) | Online (Henry's server) |
|---|---|---|
| City building, 8 buildings, queues, speedups | ✅ full sim | ✅ server-authoritative |
| Idle gains while away (+ "while you were away" sheet) | ✅ | ✅ server computes |
| Troop training (3 tiers), research tree | ✅ | ✅ (research UI shows a phase-1-server notice until the server endpoint ships) |
| Frost-node map, marches, recall, battle reports | ✅ local 24×24 wilds | ✅ shared world map |
| Commander summoning, visible pity (epic ≤ 30) | ✅ local pity | ✅ server rolls |
| Daily quests, 7-day welcome track, inventory | ✅ no streaks to break | ✅ |
| Worlds, Apple sign-in, alliances | — | ✅ (alliance UI is data-ready; full alliance UX is phase 2) |
| City shield | stub (honest "phase 2" note) | stub |
| PvP city attacks, alliance wars, leaderboards, rallies, seasons, trading | — | phase 2 |

## Monetization (all Apple IAP — no external billing, no web links)

| Product ID | Type | Price | Grants |
|---|---|---|---|
| `app.emberfall.game.removeads` | non-consumable | $4.99 | No ads, ever. Restorable; refunds bring ads back. |
| `app.emberfall.game.bundle.speedup` | consumable | $1.99 | 3× 15-minute speedups for any queue. |
| `app.emberfall.game.summon.epic10` | consumable | $4.99 | One 10× commander summon. |

Only **verified** StoreKit 2 transactions grant anything; unverified transactions never grant. Consumables grant exactly once per transaction (a persisted granted-transaction set survives crashes/redeliveries). Offline, consumables grant locally; online, the verified transaction id rides on the next server call for server-side receipt verification (see Protocol notes).

**Ads (AdMob, GMA 11.x via SPM):**
- Rewarded ("watch an ad → free 15-min speedup") — explicit opt-in from any queue, never forced.
- Interstitial — **only** on the non-gameplay transition of leaving Settings, at most once per session, never in the first 2 sessions, never within 60s of launch. Never during build/march/battle.
- `#if DEBUG` builds use Google's official test IDs; release builds carry `TODO(Henry)` placeholders.

### AdMob checklist for Henry
- [ ] Create the AdMob iOS app for `app.emberfall.game`
- [ ] Create one **Rewarded** ad unit → paste into `AdsManager.rewardedAdUnitID` (release branch)
- [ ] Create one **Interstitial** ad unit → paste into `AdsManager.interstitialAdUnitID` (release branch)
- [ ] Replace the AdMob **app ID** in `Info.plist` (`GADApplicationIdentifier`, currently the test ID with a `TODO(Henry)`)
- [ ] Privacy: `PrivacyInfo.xcprivacy` declares Device ID for third-party advertising, linked=false, tracking=false (already in repo)

### App Store Connect checklist for Henry
- [ ] App record for `app.emberfall.game`
- [ ] Create the 3 IAP products with the **exact** IDs and prices above
- [ ] Banking/tax agreements complete
- [ ] Provisioning profile with **Sign in with Apple** capability; bundle-specific GitHub environment `app-store-release-emberfall` with `APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_P12_PASSWORD`, `APPLE_PROFILE_BASE64`, `APP_STORE_CONNECT_KEY_BASE64`
- [ ] Upload `~/workspace/your_files/emberfall-apple-release.yml` via the GitHub web UI (GitHub blocks pushing `.github/workflows/` with the app token)
- [ ] Supply the production kingdom-server domain (entered in Settings → Kingdom Server)

## Adding theme variant #2 (no logic fork)

1. Copy `Emberfall/Theme/Themes/emberfall.json` → `Emberfall/Theme/Themes/<newid>.json`.
2. Rewrite: `id`, `displayName`, `tagline`, `cityName`, full `palette`, all 8 `buildings` (keep the 8 **keys**: `citadel farm lumber quarry goldmint barracks academy walls`), `troops` (keep the 4 keys), `tiers`, `research` (keep the keys), `enemy` (identity, node names, victory/defeat lines), `commanders` pools, and all copy blocks (`tutorial`, `quests`, `welcome`, `away`, `relief`, `shieldStub`).
3. Add art if the variant needs it (icons are SF Symbols by name today).
4. New Xcode target / flavor with a new bundle ID and Info.plist `EmberThemeID = <newid>`.
5. Game logic stays untouched — `ThemePack.load` picks the pack by `EmberThemeID` at launch.

## Protocol notes (frozen contract)

Base: `https://<server>/v1`. Bearer access-JWT on everything except `auth/*`. Every non-auth mutation sends `Idempotency-Key: <uuid>`; **retries reuse the same key** (401 → one silent refresh → retry with the same key). WebSocket: `wss://<server>/v1/ws?token=<access>`.

Endpoints implemented: `auth/apple`, `auth/dev` (**`#if DEBUG` only — never compiled into review builds**), `auth/refresh`, `worlds`, `worlds/{id}/join`, `worlds/{id}/config`, `worlds/{id}/alliances`, `alliances/{id}/join|leave`, `cities/{id}`, `cities/{id}/build`, `cities/{id}/train`, `build-queue/{id}/cancel|speedup`, `marches` (+`/{id}/recall`), `map`, `reports`, `commanders`, `commanders/summon`, `quests` (+`/{id}/claim`), `welcome` (+`/claim`), `inventory`, `inventory/use`, `sync`.

### Deviations & gaps (explicit — the frozen contract does not silently drift)
1. **`transaction_id` extension.** `build`, `speedup`, `train`, `summon`, and `inventory/use` accept an *optional* `transaction_id` carrying the verified App Store transaction id so the server can verify receipts. Optional and additive; omitted entirely when no purchase is involved. Full server-side receipt verification is otherwise a phase-2 server task.
2. **No research endpoint in the frozen contract.** `GameState.startResearch` online currently surfaces an honest in-UI notice ("Research on the server arrives with the phase-1 server build") instead of inventing an endpoint. The sibling server builder (or Henry) must add `POST /v1/cities/{id}/research {key}` (or confirm the intended path); then this client needs a one-method addition.
3. **`GET /v1/worlds/{id}/config`** returns theme-tunable tuning; the client falls back to bundled `offline_config.json` if absent.
4. **`GET /v1/reports`** accepts a bare array or a `{reports:[...]}` envelope.

## Building

No Swift toolchain on this Linux VM — the first real compile happens on GitHub's macOS runners via `apple-release.yml` (or any Xcode 16+ checkout).

```bash
python3 tools/gen_pbxproj.py        # regenerate Emberfall.xcodeproj + shared scheme
python3 scripts/generate_icons.py   # regenerate 9 app icons + Contents.json
python3 scripts/apple-release-check.py  # release-safety gate (also runs in CI)
```

## Files Henry never touches
- `scripts/apple-release.py` — Team `5U37FQG3VS`, ASC key `6K3UZ87UDR`, issuer `771d7892-7290-42e8-b8be-b7154988b623` (same Apple account as his other games; verify before first release).

## Changelog
See `CHANGELOG.md`. Conventions and review rules: see `VISION.md`.
