"""Build the existing game and capture a real iOS Simulator startup.

No signing material, Apple upload, purchases, or deployment is used. The .app
artifact runs on a compatible Mac simulator, not on an iPhone or Windows.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time

OUTPUT = Path("simulator-output")


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    OUTPUT.mkdir(exist_ok=True)
    proof = {"status": "started", "scope": "native compile and simulator startup only",
             "signing": False, "purchases_tested": False, "full_playtest": False,
             "revision": os.environ.get("GITHUB_SHA", "local")}
    device_id = None
    try:
        proof["xcode"] = run("xcodebuild", "-version").strip()
        with (OUTPUT / "build.log").open("w") as log:
            subprocess.run([
                "xcodebuild", "-project", "Emberfall.xcodeproj", "-scheme", "Emberfall",
                "-configuration", "Debug", "-sdk", "iphonesimulator",
                "-destination", "generic/platform=iOS Simulator", "-derivedDataPath",
                ".ai/tmp/simulator-build", "-jobs", "2", "CODE_SIGNING_ALLOWED=NO", "build",
            ], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1000)
        app = Path(".ai/tmp/simulator-build/Build/Products/Debug-iphonesimulator/Emberfall.app")
        with (app / "Info.plist").open("rb") as file:
            bundle = plistlib.load(file)["CFBundleIdentifier"]
        if bundle != "app.emberfall.game":
            raise RuntimeError("Unexpected application identity")
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(OUTPUT / "Emberfall-Simulator.zip"))
        devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))
        candidates = [d for runtime, entries in devices["devices"].items() if "iOS" in runtime
                      for d in entries if d.get("isAvailable") and d["name"].startswith("iPhone")]
        if not candidates:
            raise RuntimeError("No installed iPhone simulator runtime")
        device = next((d for d in candidates if d["state"] == "Booted"), candidates[0])
        device_id = device["udid"]
        if device["state"] != "Booted":
            run("xcrun", "simctl", "boot", device_id)
        run("xcrun", "simctl", "bootstatus", device_id, "-b")
        run("xcrun", "simctl", "install", device_id, str(app))
        proof["launch"] = run("xcrun", "simctl", "launch", device_id, bundle).strip()
        time.sleep(8)
        run("xcrun", "simctl", "io", device_id, "screenshot", str(OUTPUT / "startup.png"))
        proof.update(status="startup_captured", bundle_id=bundle, simulator=device["name"])
        (OUTPUT / "INSTALL.txt").write_text(
            "Requires a Mac with Xcode and a compatible iOS Simulator. Unzip Emberfall-Simulator.zip.\n"
            "Boot an iPhone simulator, then run: xcrun simctl install booted /absolute/path/Emberfall.app\n"
            "Launch: xcrun simctl launch booted app.emberfall.game\n"
            "This is NOT an iPhone IPA, TestFlight build, or full gameplay acceptance.\n", encoding="utf-8")
    except Exception as error:
        proof.update(status="failed", error=str(error))
        raise
    finally:
        (OUTPUT / "evidence.json").write_text(json.dumps(proof, indent=2), encoding="utf-8")
        if device_id:
            subprocess.run(["xcrun", "simctl", "shutdown", device_id], check=False, capture_output=True)


if __name__ == "__main__":
    main()
