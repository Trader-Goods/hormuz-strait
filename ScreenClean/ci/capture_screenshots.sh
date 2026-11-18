#!/bin/bash
# Release screenshots of the home screen and the black cleaning screen.
set -euo pipefail

OUT="${1:-artifacts/screenshots}"
mkdir -p "$OUT"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJ="$ROOT/ScreenClean/ScreenClean.xcodeproj"
REL="${RUNNER_TEMP:-/tmp}/screenclean-review"

python3 - << 'PY' > "$RUNNER_TEMP/screenclean-review-devices.txt"
import json, subprocess, sys
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))
ios = [r for r in runtimes.get("runtimes", []) if r.get("isAvailable") and "iOS" in r.get("name", "")]
ios.sort(key=lambda item: [int(part) if part.isdigit() else 0 for part in item.get("version", "0").split(".")])
if not ios:
    sys.exit("no iOS simulator runtime")
type_ids = {t.get("name"): t.get("identifier") for t in types.get("devicetypes", [])}
found = {}
for runtime_name, items in devices.get("devices", {}).items():
    if "iOS" not in runtime_name:
        continue
    for item in items:
        if item.get("isAvailable"):
            found.setdefault(item["name"], item["udid"])

def ensure(name):
    if name in found:
        return found[name]
    ident = type_ids.get(name)
    if not ident:
        return None
    for runtime in reversed(ios):
        try:
            return subprocess.check_output(
                ["xcrun", "simctl", "create", "Screen Clean " + name, ident, runtime["identifier"]],
                text=True, stderr=subprocess.STDOUT,
            ).strip()
        except subprocess.CalledProcessError as error:
            print(name, runtime.get("name"), (error.output or "")[-200:], file=sys.stderr)
    return None

wanted = [
    ("67", ["iPhone 15 Pro Max", "iPhone 14 Pro Max", "iPhone 16 Plus", "iPhone 15 Plus"]),
    ("65", ["iPhone 14 Plus", "iPhone 13 Pro Max", "iPhone 12 Pro Max", "iPhone 11 Pro Max"]),
]
for kind, names in wanted:
    chosen = None
    for name in names:
        udid = ensure(name)
        if udid:
            chosen = (name, udid)
            break
    if not chosen:
        sys.exit("no " + kind + " inch iPhone simulator")
    print(kind + "\t" + chosen[1] + "\t" + chosen[0])
PY

REVIEW_UDID=$(head -n 1 "$RUNNER_TEMP/screenclean-review-devices.txt" | cut -f2)
xcodebuild \
  -project "$PROJ" \
  -scheme ScreenClean \
  -configuration Release \
  -destination "platform=iOS Simulator,id=$REVIEW_UDID" \
  -derivedDataPath "$REL" \
  CODE_SIGNING_ALLOWED=NO \
  build
RELAPP="$(find "$REL" -path '*Release-iphonesimulator/ScreenClean.app' -print -quit)"
test -n "$RELAPP"

while IFS=$'\t' read -r KIND EXTRA_UDID EXTRA_NAME; do
  [ -n "${EXTRA_UDID:-}" ] || continue
  xcrun simctl boot "$EXTRA_UDID" || true
  xcrun simctl bootstatus "$EXTRA_UDID" -b
  sleep 6
  xcrun simctl ui "$EXTRA_UDID" appearance dark || true
  xcrun simctl install "$EXTRA_UDID" "$RELAPP"
  xcrun simctl status_bar "$EXTRA_UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 || true
  xcrun simctl launch "$EXTRA_UDID" com.tradergoods.screenclean -screenshot home || true
  sleep 8
  xcrun simctl terminate "$EXTRA_UDID" com.tradergoods.screenclean || true
  for SHOT in home clean; do
    FILE="$OUT/review-$KIND-$SHOT.png"
    xcrun simctl terminate "$EXTRA_UDID" com.tradergoods.screenclean || true
    sleep 1
    xcrun simctl launch "$EXTRA_UDID" com.tradergoods.screenclean -screenshot "$SHOT"
    sleep 8
    xcrun simctl io "$EXTRA_UDID" screenshot "$FILE"
    test -s "$FILE"
  done
  xcrun simctl shutdown "$EXTRA_UDID" || true
done < "$RUNNER_TEMP/screenclean-review-devices.txt"

python3 - << PY
import pathlib, struct, sys
out = pathlib.Path("$OUT")
expect = {"67": {(1290, 2796), (1260, 2736)}, "65": {(1284, 2778), (1242, 2688)}}
for kind, sizes in expect.items():
    for shot in ("home", "clean"):
        path = out / f"review-{kind}-{shot}.png"
        data = path.read_bytes()
        if data[1:4] != b"PNG":
            sys.exit(path.name + " is not a png")
        width, height = struct.unpack(">II", data[16:24])
        print(path.name, width, height)
        if (width, height) not in sizes:
            sys.exit(f"{path.name} is {width}x{height}")
PY
ls -lh "$OUT"
