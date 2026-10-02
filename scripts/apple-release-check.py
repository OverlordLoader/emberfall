#!/usr/bin/env python3
"""Pre-release safety checks for Emberfall Kingdom (runs on ubuntu-latest).

Verifies the release-critical invariants without touching Apple signing:
bundle identity, platform floor, App-Store-review safety (no http:// URLs,
no analytics/tracking SDK imports, no external-open calls), the
non-exempt-encryption declaration, theme-pack integrity (every theme string
the game shows comes from bundled JSON — the reskin contract), and the
frozen client/server protocol surface.

The release workflow is versioned in this repository; signing remains manual.
"""

import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPECTED_BUNDLE = "app.emberfall.game"
EXPECTED_DISPLAY_NAME = "Emberfall Kingdom"
MIN_DEPLOYMENT = (17, 0)

# Third-party analytics and advertising SDKs excluded from this game.
# Emberfall Kingdom is fully AD-FREE: no advertising SDK is allowed at all.
# (GoogleMobileAds is banned — the game ships with zero ads.)
BANNED_IMPORTS = [
    "GoogleMobileAds",
    "Firebase",
    "AppTrackingTransparency",
    "AdSupport",
    "Facebook",
    "Amplitude",
    "Mixpanel",
]

failures = []


def check(condition, message):
    print(("PASS" if condition else "FAIL") + ": " + message)
    if not condition:
        failures.append(message)


def main():
    info_path = ROOT / "Emberfall" / "Info.plist"
    check(info_path.exists(), "Emberfall/Info.plist exists")
    if info_path.exists():
        with info_path.open("rb") as fh:
            info = plistlib.load(fh)
        check(info.get("CFBundleDisplayName") == EXPECTED_DISPLAY_NAME,
              f"CFBundleDisplayName == {EXPECTED_DISPLAY_NAME}")
        check(info.get("ITSAppUsesNonExemptEncryption") is False,
              "ITSAppUsesNonExemptEncryption is false (no export-compliance prompt)")
        orientations = info.get("UISupportedInterfaceOrientations", [])
        check(orientations == ["UIInterfaceOrientationPortrait"],
              "portrait-only orientations declared")
        check(info.get("GADApplicationIdentifier") is None,
              "no GADApplicationIdentifier (ad-free game — no AdMob)")

    pbx = ROOT / "Emberfall.xcodeproj" / "project.pbxproj"
    check(pbx.exists(), "Emberfall.xcodeproj/project.pbxproj exists")
    if pbx.exists():
        text = pbx.read_text()
        check(f"PRODUCT_BUNDLE_IDENTIFIER = {EXPECTED_BUNDLE};" in text,
              f"bundle identifier {EXPECTED_BUNDLE} present in project")
        m = re.search(r"IPHONEOS_DEPLOYMENT_TARGET = ([0-9]+)\.([0-9]+);", text)
        if m:
            ver = (int(m.group(1)), int(m.group(2)))
            check(ver >= MIN_DEPLOYMENT, f"deployment target {ver} >= 17.0")
        else:
            check(False, "deployment target found in project")
        check("CODE_SIGN_ENTITLEMENTS" in text,
              "Sign in with Apple entitlements wired in project")

    # Theme-pack integrity: the reskin contract.
    theme_path = ROOT / "Emberfall" / "Theme" / "Themes" / "emberfall.json"
    check(theme_path.exists(), "Themes/emberfall.json exists")
    if theme_path.exists():
        theme = json.loads(theme_path.read_text())
        for key in ["id", "displayName", "palette", "buildings", "troops",
                    "research", "enemy", "commanders", "tutorial"]:
            check(key in theme, f"theme pack has '{key}' section")
        check(len(theme.get("buildings", [])) == 8, "theme defines 8 buildings")
        check(len(theme.get("research", [])) >= 5, "theme defines 5+ research nodes")

    cfg_path = ROOT / "Emberfall" / "Config" / "offline_config.json"
    check(cfg_path.exists(), "Config/offline_config.json exists (offline tuning)")

    # Review safety: banned imports / tracking.
    swift_files = list((ROOT / "Emberfall").rglob("*.swift"))
    check(len(swift_files) > 0, f"{len(swift_files)} Swift sources present")
    for ban in BANNED_IMPORTS:
        hits = [f for f in swift_files if re.search(rf"import\s+{ban}\b", f.read_text())]
        check(not hits, f"no '{ban}' imports ({len(hits)} hits)")

    # No hardcoded http:// API URLs (server URL comes from Settings; the two
    # scheme-strip lines in WSClient.swift are intentional).
    http_hits = []
    for f in swift_files:
        for i, line in enumerate(f.read_text().splitlines(), 1):
            if "http://" in line and "replacingOccurrences" not in line \
                    and "schemas" not in line.lower() and "w3.org" not in line:
                http_hits.append(f"{f.name}:{i}")
    check(not http_hits, f"no hardcoded http:// URLs ({len(http_hits)} hits)")

    # Frozen protocol surface: every contract endpoint has a client method.
    api = (ROOT / "Emberfall" / "Net" / "APIClient.swift").read_text()
    for needle in ["auth/apple", "auth/refresh", "worlds/", "cities/",
                   "build-queue/", "marches", "commanders/summon",
                   "quests", "welcome", "inventory", "alliances", "sync?since="]:
        check(needle in api, f"APIClient covers '{needle}'")
    ws = (ROOT / "Emberfall" / "Net" / "WSClient.swift").read_text()
    for needle in ["subscribe_map", "chat_send", "ping", "battle_report", "march_update"]:
        check(needle in ws, f"WSClient covers '{needle}'")

    # IAP product IDs match the documented contract (ad-free: no removeads).
    store = (ROOT / "Emberfall" / "Game" / "StoreManager.swift").read_text()
    for pid in ["app.emberfall.game.bundle.speedup",
                "app.emberfall.game.summon.epic10",
                "app.emberfall.game.bundle.warden"]:
        check(pid in store, f"StoreManager declares '{pid}'")
    check("app.emberfall.game.removeads" not in store,
          "no removeads product (ad-free game)")

    # Ad-free hardening: the ads system must be fully gone.
    check(not (ROOT / "Emberfall" / "Game" / "AdsManager.swift").exists(),
          "AdsManager.swift deleted")
    ad_hits = []
    for f in swift_files:
        for i, line in enumerate(f.read_text().splitlines(), 1):
            if re.search(r"GoogleMobileAds|AdsManager|showRewarded|Interstitial|rewardedAd",
                         line, re.IGNORECASE):
                ad_hits.append(f"{f.name}:{i}")
    check(not ad_hits, f"no ad-system references in Swift ({len(ad_hits)} hits)")
    pbx_text = (ROOT / "Emberfall.xcodeproj" / "project.pbxproj").read_text()
    check("GoogleMobileAds" not in pbx_text and "swift-package-manager-google-mobile-ads" not in pbx_text,
          "no AdMob SPM package in project")

    # Privacy manifest: no ads or tracking; online account/game/chat data is collected.
    priv = ROOT / "Emberfall" / "PrivacyInfo.xcprivacy"
    check(priv.exists(), "PrivacyInfo.xcprivacy exists")
    if priv.exists():
        with priv.open("rb") as fh:
            manifest = plistlib.load(fh)
        check(manifest.get("NSPrivacyTracking") is False, "NSPrivacyTracking is false")
        collected = manifest.get("NSPrivacyCollectedDataTypes", [])
        expected_types = {"NSPrivacyCollectedDataType" + kind for kind in ["UserID", "DeviceID", "GameplayContent", "OtherUserContent"]}
        check({item.get("NSPrivacyCollectedDataType") for item in collected} == expected_types,
              "account, device, gameplay and chat collection is declared")
        check(all(item.get("NSPrivacyCollectedDataTypeLinked") is True and item.get("NSPrivacyCollectedDataTypeTracking") is False for item in collected),
              "online data is linked to the account, not used for tracking")

    # Theme art integrity: every sprite named in the theme's art section
    # exists as an imageset in the theme's asset-catalog folder. Missing art
    # must fail loudly here — never as a blank in the game.
    art = theme.get("art", {}) if 'theme' in dir() else {}
    if theme_path.exists():
        art = json.loads(theme_path.read_text()).get("art", {})
        catalog = ROOT / "Emberfall" / "Assets.xcassets" / "Emberfall"
        expected = []
        for key, b in (art.get("buildings") or {}).items():
            for s in range(1, (b.get("stages") or 0) + 1):
                expected.append(f"{b['sprite']}_s{s}")
        for section in ["resources", "terrain", "ui", "onboarding"]:
            expected += list((art.get(section) or {}).values())
        for ttype, tiers in (art.get("troops") or {}).items():
            expected += list(tiers.values())
        expected += list((art.get("enemies") or {}).values())
        expected += list((art.get("commanders") or {}).values())
        missing_art = [n for n in expected
                       if not (catalog / f"{n}.imageset").is_dir()]
        check(expected != [], f"theme art section names {len(expected)} assets")
        check(not missing_art,
              f"all theme art assets exist in catalog ({len(missing_art)} missing)")

    workflow = ROOT / ".github" / "workflows" / "apple-release.yml"
    check(workflow.exists(), "versioned release workflow exists")
    if workflow.exists():
        wf = workflow.read_text()
        check("environment: app-store-release-emberfall" in wf, "dedicated release environment")
        check("APP_BUNDLE_ID: app.emberfall.game" in wf, "workflow bundle identity")

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED")
        sys.exit(1)
    print("all release safety checks passed")


if __name__ == "__main__":
    main()
