# Changelog

## 1.0.0 — 2026-09-30 (initial build, unreleased)
- Initial client: SwiftUI + SpriteKit, iOS 17+, portrait, bundle `app.emberfall.game`.
- Data-driven ThemePack (`emberfall.json`): ember-vs-frost identity, palette, 8 buildings, 4 troops, 3 tiers, research, enemy, commander pools, all narrative copy. Variant #2 needs only new JSON + bundle ID.
- Frozen REST/WS client: bearer JWT, per-call idempotency keys reused across 401-refresh retries, wss-only WebSocket with auto-reconnect and backoff.
- Complete offline PvE sim: persistent save, idle gains + away sheet, 8×8 city, 8 buildings, build/train/research queues, speedups, 3 troop tiers, research tree, 24×24 frost-node wilds, marches + recall, offline battle resolver, reports + loot, commander gacha with visible pity (epic ≤ 30), daily quests, 7-day welcome track (no streaks), inventory, power, loss-relief.
- Monetization day one: 3 exact IAPs (removeads $4.99 non-consumable; speedup bundle $1.99 consumable; summon epic10 $4.99 consumable), verified-only grants, exactly-once consumable grants, refund-aware remove-ads; AdMob rewarded speedups + sparse interstitial (never mid-gameplay), test IDs in DEBUG, TODO(Henry) placeholders in release.
- Paywall + shop in Settings, restore purchases, honest phase-2 shield stub, debug-only dev sign-in and save reset.
- Release infra: generated Xcode project + scheme, 9 app icons, `scripts/apple-release.py`, `scripts/apple-release-check.py` (safety gate), privacy manifest (Device ID for advertising, linked=false, tracking=false), portrait-only Info.plist with `EmberThemeID`.
- Protocol notes: `transaction_id` documented as an optional additive extension; online research deferred to the phase-1 server endpoint; report envelope tolerance documented.
