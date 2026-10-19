#!/usr/bin/env python3
"""Build Live to Still, seed generic photos, and capture 1320x2868 screenshots.

This does not sign for the App Store and does not upload a build.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHOT_DIR = Path("/tmp/appstore-screenshots")
OUT_DIR = ROOT / "artifacts" / "screenshots"
LOG_DIR = ROOT / "artifacts" / "logs"
MEDIA_DIR = ROOT / "scripts" / "screenshots" / "Seed" / "SampleMedia"
EXPECTED = [
    "01-home.png",
    "02-convert-results.png",
    "03-delete-copies-keep-edited.png",
    "04-delete-copies-keep-original.png",
    "05-empty-recently-deleted.png",
]
PREFERRED_DEVICES = [
    "iPhone 16 Pro Max",
    "iPhone 17 Pro Max",
    "iPhone 18 Pro Max",
]


def log(message):
    print(message, flush=True)


def run(cmd, cwd=None, timeout=None):
    log("+ " + " ".join(cmd))
    subprocess.run(cmd, cwd=cwd or ROOT, check=True, timeout=timeout)


def run_logged(cmd, log_path, cwd=None, timeout=None):
    log("+ " + " ".join(cmd))
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as handle:
        process = subprocess.Popen(
            cmd,
            cwd=cwd or ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            handle.write(line)
        code = process.wait(timeout=timeout)
    if code != 0:
        raise SystemExit(f"command failed ({code}): {' '.join(cmd)}")


def png_size(path):
    output = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], text=True)
    width = int(re.search(r"pixelWidth: (\d+)", output).group(1))
    height = int(re.search(r"pixelHeight: (\d+)", output).group(1))
    return width, height


def newest_runtimes():
    payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
    runtimes = [item for item in payload.get("runtimes", []) if item.get("isAvailable")]
    runtimes.sort(key=lambda item: item.get("version", ""), reverse=True)
    return runtimes


def device_type_id(name):
    payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))
    for item in payload.get("devicetypes", []):
        if item.get("name") == name:
            return item["identifier"]
    return None


def boot_matching_simulator():
    subprocess.run(["xcrun", "simctl", "shutdown", "all"], check=False)
    runtimes = newest_runtimes()
    if not runtimes:
        raise SystemExit("no iOS simulator runtimes are available")
    errors = []
    for name in PREFERRED_DEVICES:
        device_id = device_type_id(name)
        if not device_id:
            errors.append(f"{name} is not installed")
            continue
        for runtime in runtimes:
            if not runtime.get("name", "").startswith("iOS"):
                continue
            try:
                udid = subprocess.check_output(
                    ["xcrun", "simctl", "create", "LiveToStillShots", device_id, runtime["identifier"]],
                    text=True,
                ).strip()
            except subprocess.CalledProcessError as error:
                errors.append(f"{name} on {runtime.get('name')} was not created ({error.returncode})")
                continue
            run(["xcrun", "simctl", "boot", udid])
            run(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=180)
            subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], check=False)
            probe = SHOT_DIR / "probe.png"
            SHOT_DIR.mkdir(parents=True, exist_ok=True)
            subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", str(probe)], check=True)
            width, height = png_size(probe)
            log(f"{name} / {runtime.get('name')} screenshot is {width}x{height}")
            probe.unlink(missing_ok=True)
            if (width, height) == (1320, 2868):
                return udid, name, runtime.get("name")
            subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)
            subprocess.run(["xcrun", "simctl", "delete", udid], check=False)
            errors.append(f"{name} on {runtime.get('name')} is {width}x{height}")
    raise SystemExit("no 1320x2868 simulator\n" + "\n".join(errors))


def sign_and_install(udid, app):
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=False)
    run(["xcrun", "simctl", "install", udid, str(app)])


def collect_simulator_screenshots(udid):
    root = Path.home() / "Library" / "Developer" / "CoreSimulator" / "Devices" / udid
    if not root.exists():
        log(f"simulator data missing at {root}")
        return
    for path in root.rglob("*.png"):
        if path.name not in EXPECTED:
            continue
        destination = SHOT_DIR / path.name
        if not destination.exists() or path.stat().st_mtime >= destination.stat().st_mtime:
            shutil.copy2(path, destination)
            log(f"collected {path} -> {destination}")


def grant_photos(udid, bundle_id):
    for service in ("photos", "photos-add"):
        result = subprocess.run(
            ["xcrun", "simctl", "privacy", udid, "grant", service, bundle_id],
            text=True,
            capture_output=True,
        )
        log(f"privacy grant {service} {bundle_id} -> {result.returncode} {result.stdout} {result.stderr}")


def wait_for_seed(udid):
    launched = subprocess.run(
        ["xcrun", "simctl", "launch", udid, "com.tradergoods.screenshotseed"],
        text=True,
        capture_output=True,
    )
    log(launched.stdout)
    log(launched.stderr)
    if launched.returncode != 0:
        raise SystemExit(f"seed app failed to launch ({launched.returncode})")
    container = subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", udid, "com.tradergoods.screenshotseed", "data"],
        text=True,
    ).strip()
    report = Path(container) / "Documents" / "seed-result.txt"
    started = Path(container) / "Documents" / "seed-started.txt"
    deadline = time.time() + 120
    while time.time() < deadline:
        if report.exists():
            text = report.read_text()
            log(text)
            subprocess.run(["xcrun", "simctl", "terminate", udid, "com.tradergoods.screenshotseed"], check=False)
            if not text.startswith("ok"):
                raise SystemExit(text)
            return
        time.sleep(1)
    log(f"seed started file exists={started.exists()}")
    for name in ("seed-started.txt", "seed-status.txt", "seed-result.txt"):
        path = Path(container) / "Documents" / name
        log(f"{name} exists={path.exists()} {path.read_text() if path.exists() else ''}")
    raise SystemExit("sample photo seed did not finish")


def main():
    os.chdir(ROOT)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    SHOT_DIR.mkdir(parents=True, exist_ok=True)
    for stale in SHOT_DIR.glob("*.png"):
        stale.unlink()
    run(["xcodebuild", "-version"])
    udid, device_name, runtime_name = boot_matching_simulator()
    log(f"using {device_name} on {runtime_name} ({udid})")
    run([
        "xcrun", "swiftc", "-parse-as-library", "-O",
        "-framework", "AVFoundation",
        "-framework", "CoreGraphics",
        "-framework", "ImageIO",
        "-framework", "CoreMedia",
        "-framework", "CoreVideo",
        "-framework", "UniformTypeIdentifiers",
        str(ROOT / "scripts" / "screenshots" / "GenerateMedia.swift"),
        "-o", "/tmp/generate-media",
    ])
    run(["/tmp/generate-media", str(MEDIA_DIR)])

    sign = [
        "CODE_SIGN_IDENTITY=-",
        "CODE_SIGN_STYLE=Manual",
        "CODE_SIGNING_REQUIRED=NO",
        "CODE_SIGNING_ALLOWED=YES",
        "DEVELOPMENT_TEAM=",
    ]
    destination = f"platform=iOS Simulator,id={udid}"
    run_logged(
        ["xcodebuild", "-project", "scripts/screenshots/Seed.xcodeproj", "-scheme", "Seed", "-configuration", "Debug", "-destination", destination, "-derivedDataPath", "artifacts/derived-seed", *sign, "build"],
        LOG_DIR / "seed-build.log",
        timeout=900,
    )
    run_logged(
        ["xcodebuild", "-project", "LiveToStill.xcodeproj", "-scheme", "LiveToStill", "-configuration", "Debug", "-destination", destination, "-derivedDataPath", "artifacts/derived-app", *sign, "build"],
        LOG_DIR / "app-build.log",
        timeout=900,
    )
    seed_app = ROOT / "artifacts" / "derived-seed" / "Build" / "Products" / "Debug-iphonesimulator" / "Seed.app"
    live_app = ROOT / "artifacts" / "derived-app" / "Build" / "Products" / "Debug-iphonesimulator" / "LiveToStill.app"
    if not seed_app.exists() or not live_app.exists():
        raise SystemExit(f"missing built app seed={seed_app.exists()} live={live_app.exists()}")
    sign_and_install(udid, seed_app)
    grant_photos(udid, "com.tradergoods.screenshotseed")

    sign_and_install(udid, live_app)
    grant_photos(udid, "com.tradergoods.livetostill")
    subprocess.run(
        ["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4"],
        check=False,
    )
    try:
        run_logged(
            ["xcodebuild", "test", "-project", "scripts/screenshots/ShotHost.xcodeproj", "-scheme", "ShotHost", "-destination", destination, "-derivedDataPath", "artifacts/derived-tests", "-only-testing:ShotUITests/ScreenshotUITests/testCapture", *sign],
            LOG_DIR / "uitest.log",
            timeout=900,
        )
    finally:
        collect_simulator_screenshots(udid)
        report = subprocess.run(
            ["xcrun", "simctl", "get_app_container", udid, "com.tradergoods.screenshotseed", "data"],
            text=True,
            capture_output=True,
        )
        if report.returncode == 0:
            result = Path(report.stdout.strip()) / "Documents" / "seed-result.txt"
            log(f"seed result exists={result.exists()} {result.read_text() if result.exists() else ''}")
        for name in EXPECTED:
            source = SHOT_DIR / name
            if source.exists():
                shutil.copy2(source, OUT_DIR / name)
    missing = [name for name in EXPECTED if not (OUT_DIR / name).exists()]
    if missing:
        raise SystemExit("missing screenshots: " + ", ".join(missing))
    for name in EXPECTED:
        width, height = png_size(OUT_DIR / name)
        log(f"{name} {width}x{height}")
        if (width, height) != (1320, 2868):
            raise SystemExit(f"{name} is {width}x{height}, expected 1320x2868")
    log("captured 5 screenshots at 1320x2868")


if __name__ == "__main__":
    main()
