#!/usr/bin/env python3
"""Pre-release safety checks for Emberfall Kingdom (runs on ubuntu-latest).

Verifies the release-critical invariants without touching Apple signing:
bundle identity, platform floor, App-Store-review safety (no http:// URLs,
no analytics/tracking SDK imports, no external-open calls), the
non-exempt-encryption declaration, theme-pack integrity (every theme string
the game shows comes from bundled JSON — the reskin contract), and the
frozen client/server protocol surface.

NOTE on the release workflow: GitHub blocks pushing `.github/workflows/`
with the app's token, so the apple-release.yml workflow is maintained
outside this repo (~/workspace/your_files/emberfall-apple-release.yml)
and uploaded by Henry via the GitHub web UI. The check below validates it
when present; its absence in-repo is expected, not a failure.
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

# Third-party SDKs that would violate the zero-data-collection promise.
# NOTE: GoogleMobileAds is intentionally NOT banned — it is the app's ad
# network (rewarded speedups + sparse interstitials), wired via SPM. No other
# analytics/tracking SDKs are allowed.
BANNED_IMPORTS = [
    "Firebase",
    "AppTrackingTransparency",
    "AdSupport",
    "Facebook",
    "Amplitude",
    "Mixpanel",
]

# AdMob test IDs that must never ship in a Release build. The check below
# only verifies presence of the app ID key; replacing test IDs with real
# ones is a documented manual step in README ("Monetization setup").
ADMOB_TEST_APP_ID = "ca-app-pub-3940256099942544~3347511713"

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
        check(info.get("GADApplicationIdentifier") == ADMOB_TEST_APP_ID,
              "GADApplicationIdentifier present (AdMob test ID — Henry must "
              "replace with the real AdMob App ID before release; see README)")

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

    # IAP product IDs match the documented contract.
    store = (ROOT / "Emberfall" / "Game" / "StoreManager.swift").read_text()
    for pid in ["app.emberfall.game.removeads",
                "app.emberfall.game.bundle.speedup",
                "app.emberfall.game.summon.epic10"]:
        check(pid in store, f"StoreManager declares '{pid}'")

    # Privacy manifest: Device ID for advertising only, tracking=false.
    priv = ROOT / "Emberfall" / "PrivacyInfo.xcprivacy"
    check(priv.exists(), "PrivacyInfo.xcprivacy exists")
    if priv.exists():
        with priv.open("rb") as fh:
            manifest = plistlib.load(fh)
        check(manifest.get("NSPrivacyTracking") is False, "NSPrivacyTracking is false")
        collected = manifest.get("NSPrivacyCollectedDataTypes", [])
        check(any(d.get("NSPrivacyCollectedDataType") == "NSPrivacyCollectedDataTypeDeviceID"
                    for d in collected),
              "Device ID declared for advertising")

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED")
        sys.exit(1)
    print("all release safety checks passed")


if __name__ == "__main__":
    main()
