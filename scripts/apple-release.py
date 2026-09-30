#!/usr/bin/env python3
"""Sign and validate one reviewed Emberfall Kingdom iOS release on an isolated macOS runner.

Native-Swift adaptation of the apple-release.py pattern used by Henry's other
apps. Same safety contract:
  * only runs on macOS, only via an explicit workflow_dispatch on refs/heads/main
  * manual signing with Henry's distribution certificate + an App Store
    provisioning profile for app.emberfall.game
  * the .ipa is always validated with altool; upload to App Store Connect is
    opt-in per dispatch and never submits for review
  * secrets are never printed (argv may contain a keychain password)
"""

import base64
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

TEAM = "5U37FQG3VS"
CERT_SHA256 = "AD55F104A48F3C2962B61298645C20617180F75EACA0A29B982AB5A263AC1B1B"
ALLOWED = {"app.emberfall.game"}
KEY_ID = "6K3UZ87UDR"
ISSUER = "771d7892-7290-42e8-b8be-b7154988b623"

APP_NAME = "Emberfall"
ROOT = Path(__file__).resolve().parent.parent
WORK = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "emberfall-apple-release"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, capture=False, cwd=None, env=None):
    # CalledProcessError argv may contain a keychain password: never print args.
    result = subprocess.run(
        [str(x) for x in args], cwd=cwd, check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None, env=env,
    )
    require(result.returncode == 0, Path(str(args[0])).name + " failed with exit code " + str(result.returncode))
    return result.stdout if capture else None


def b64env(name, path):
    raw = os.environ.get(name, "")
    require(bool(raw), f"missing secret {name}")
    path.write_bytes(base64.b64decode(raw))
    return path


def confirm_apple_result(raw, operation):
    require(operation in ("validation", "upload"), "Unknown Apple operation")
    try:
        result = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        raise RuntimeError("Apple returned an unrecognized response; delivery is not confirmed") from None
    require(isinstance(result, dict), "Apple returned an unexpected response shape")
    errors = result.get("product-errors") or result.get("errors") or result.get("error")
    if errors:
        print(json.dumps({"appleOperation": operation, "errors": errors}))
    require(not errors, "Apple reported an error; delivery is not confirmed")
    message = result.get("success-message", "")
    expected = "No errors validating" if operation == "validation" else "No errors uploading"
    require(isinstance(message, str) and message.startswith(expected),
            "Apple did not explicitly confirm " + operation)
    print(json.dumps({"appleOperation": operation, "confirmed": True, "message": message}))


def run_apple_operation(ipa, operation):
    require(operation in ("validation", "upload"), "Unknown Apple operation")
    action = "--validate-app" if operation == "validation" else "--upload-app"
    result = subprocess.run(
        ["xcrun", "altool", action, "--type", "ios", "--file", str(ipa),
         "--apiKey", KEY_ID, "--apiIssuer", ISSUER, "--output-format", "json"],
        check=False, stdout=subprocess.PIPE,
    )
    if result.returncode:
        try:
            details = json.loads(result.stdout)
        except (ValueError, UnicodeDecodeError):
            details = {}
        if isinstance(details, dict):
            errors = details.get("product-errors") or details.get("errors") or details.get("error")
            if errors:
                print(json.dumps({"appleOperation": operation, "errors": errors}), flush=True)
        raise RuntimeError("Apple " + operation + " failed with exit code " + str(result.returncode))
    confirm_apple_result(result.stdout, operation)


def validate_profile(profile, bundle):
    require(bundle in ALLOWED, "Unknown app identity")
    ent = profile["Entitlements"]
    require(profile["TeamIdentifier"] == [TEAM], "Profile belongs to another team")
    require(ent["application-identifier"] == TEAM + "." + bundle, "Profile belongs to another app")
    require(ent.get("get-task-allow", False) is False, "Development/debug profile rejected")
    require(not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"),
            "Not an App Store profile")
    require(profile["ExpirationDate"].replace(tzinfo=dt.timezone.utc)
            > dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1),
            "Profile expires too soon")
    certificates = profile["DeveloperCertificates"]
    require(len(certificates) == 1
            and hashlib.sha256(certificates[0]).hexdigest().upper() == CERT_SHA256,
            "Wrong distribution certificate")
    return profile["UUID"]


def configure_project(text, bundle, profile_uuid, build):
    require(bundle in ALLOWED, "Unknown app identity")
    require(re.fullmatch(r"[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}", build), "Invalid Apple build number")
    require(re.fullmatch(r"[A-Fa-f0-9-]{36}", profile_uuid), "Invalid profile identifier")
    changed = 0

    def replace(match):
        nonlocal changed
        body = match.group(1)
        identifier = re.search(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*\"?([^\";]+)\"?;", body)
        if not identifier:
            return match.group(0)
        require(identifier.group(1) == bundle, "Unexpected native target; signing needs explicit review")
        settings = {
            "CODE_SIGN_STYLE": "Manual",
            "DEVELOPMENT_TEAM": TEAM,
            "CODE_SIGN_IDENTITY": '"Apple Distribution"',
            "PROVISIONING_PROFILE_SPECIFIER": '"' + profile_uuid + '"',
            "CURRENT_PROJECT_VERSION": build,
        }
        for field, value in settings.items():
            expression = r"(?m)^\s*" + field + r"\s*=\s*[^;]+;"
            body = (re.sub(expression, "\n\t\t\t\t" + field + " = " + value + ";", body)
                    if re.search(expression, body)
                    else body + "\n\t\t\t\t" + field + " = " + value + ";")
        changed += 1
        return "buildSettings = {" + body + "\n" + match.group(2) + "};"

    result = re.sub(r"buildSettings = \{([\s\S]*?)\n(\s*)};", replace, text)
    require(changed == 2, "Expected exactly the App Debug and Release target configurations")
    return result


def run_release():
    require(sys.platform == "darwin", "Signing requires the macOS build runner")
    require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch",
            "Only an explicit release dispatch can sign")
    require(os.environ.get("GITHUB_REF") == os.environ["RELEASE_REF"],
            "Only the reviewed release branch can sign")
    bundle = os.environ["APP_BUNDLE_ID"]
    build = os.environ["RELEASE_BUILD_NUMBER"]
    upload = os.environ.get("UPLOAD_TO_APPLE", "false").lower() == "true"
    require(bundle in ALLOWED, "Unknown app identity")

    if WORK.exists():
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True)

    # --- Keychain with the distribution certificate ---
    keychain = WORK / "signing.keychain-db"
    keychain_pw = secrets.token_urlsafe(32)
    p12 = b64env("APPLE_DISTRIBUTION_P12_BASE64", WORK / "dist.p12")
    p12_pw = os.environ.get("APPLE_DISTRIBUTION_P12_PASSWORD", "")
    require(bool(p12_pw), "missing secret APPLE_DISTRIBUTION_P12_PASSWORD")
    run(["security", "create-keychain", "-p", keychain_pw, str(keychain)])
    run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
    run(["security", "unlock-keychain", "-p", keychain_pw, str(keychain)])
    run(["security", "import", str(p12), "-k", str(keychain), "-P", p12_pw,
         "-T", "/usr/bin/codesign", "-T", "/usr/bin/xcodebuild"])
    run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s",
         "-k", keychain_pw, str(keychain)])
    run(["security", "list-keychains", "-s", str(keychain)])

    # --- Provisioning profile ---
    prov_raw = b64env("APPLE_PROFILE_BASE64", WORK / "profile.mobileprovision")
    prov_dir = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"
    prov_dir.mkdir(parents=True, exist_ok=True)
    cms = run(["security", "cms", "-D", "-i", str(prov_raw)], capture=True)
    profile = plistlib.loads(cms)
    profile_uuid = validate_profile(profile, bundle)
    shutil.copy(prov_raw, prov_dir / (profile_uuid + ".mobileprovision"))

    # --- API key for altool ---
    api_key_p8 = b64env("APP_STORE_CONNECT_KEY_BASE64", WORK / "AuthKey.p8")
    api_key_dir = Path.home() / ".appstoreconnect" / "private_keys"
    api_key_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(api_key_p8, api_key_dir / f"AuthKey_{KEY_ID}.p8")

    # --- Patch build settings, then archive ---
    pbx_path = ROOT / f"{APP_NAME}.xcodeproj" / "project.pbxproj"
    original = pbx_path.read_text()
    pbx_path.write_text(configure_project(original, bundle, profile_uuid, build))
    try:
        archive = WORK / f"{APP_NAME}.xcarchive"
        run(["xcodebuild", "-project", f"{APP_NAME}.xcodeproj", "-target", APP_NAME,
             "-configuration", "Release",
             "-destination", "generic/platform=iOS",
             "-archivePath", str(archive), "archive"], cwd=ROOT)
        export_plist = WORK / "ExportOptions.plist"
        export_plist.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0"><dict>\n'
            "<key>method</key><string>app-store</string>\n"
            f"<key>teamID</key><string>{TEAM}</string>\n"
            "<key>uploadSymbols</key><true/>\n"
            "</dict></plist>\n")
        out_dir = ROOT / "release-output"
        out_dir.mkdir(exist_ok=True)
        run(["xcodebuild", "-exportArchive", "-archivePath", str(archive),
             "-exportPath", str(out_dir), "-exportOptionsPlist", str(export_plist)], cwd=ROOT)
    finally:
        pbx_path.write_text(original)

    ipa = out_dir / f"{APP_NAME}.ipa"
    require(ipa.exists(), f"Export did not produce {APP_NAME}.ipa")
    run_apple_operation(ipa, "validation")
    if upload:
        run_apple_operation(ipa, "upload")

    manifest = {
        "app": "Emberfall Kingdom",
        "bundle": bundle,
        "build": build,
        "uploaded": upload,
        "profile": profile_uuid,
        "team": TEAM,
    }
    (out_dir / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"release": "ok", "uploaded": upload}))


if __name__ == "__main__":
    run_release()
