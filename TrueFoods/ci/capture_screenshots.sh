#!/bin/bash
# Launch TrueFoods in one simulator and save the four review screens.
set -euo pipefail

OUT="${1:-artifacts/screenshots}"
mkdir -p "$OUT"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJ="$ROOT/TrueFoods/TrueFoods.xcodeproj"
DD="${RUNNER_TEMP:-/tmp}/truefoods-shots"
UDID="$(python3 "$ROOT/TrueFoods/ci/pick_simulator.py")"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance light || true

xcodebuild \
  -project "$PROJ" \
  -scheme TrueFoods \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$(find "$DD" -path '*Debug-iphonesimulator/TrueFoods.app' -print -quit)"
test -n "$APP"
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --batteryState charged \
  --batteryLevel 100 \
  --cellularMode active \
  --cellularBars 4 \
  --wifiBars 3 || true

# The first launch after boot can still be on the home screen when the picture is taken.
xcrun simctl launch "$UDID" com.tradergoods.madewithlove -screenshot home || true
sleep 12
xcrun simctl terminate "$UDID" com.tradergoods.madewithlove || true

capture() {
  local name="$1"
  local shot="$2"
  xcrun simctl terminate "$UDID" com.tradergoods.madewithlove || true
  xcrun simctl launch "$UDID" com.tradergoods.madewithlove -screenshot "$shot"
  sleep 8
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png"
  test -s "$OUT/$name.png"
}

capture home home
capture result result
capture score score
capture snap snap

xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large || true
capture result-large-text result || true
xcrun simctl ui "$UDID" content_size large || true

# Home on a small phone and a large phone, one simulator at a time.
python3 - << 'PY' > "$RUNNER_TEMP/truefoods-extra-devices.txt"
import json, subprocess
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
data = json.loads(raw)
wanted = ["iPhone SE (3rd generation)", "iPhone 16 Pro Max", "iPhone 15 Pro Max"]
found = {}
for runtime, items in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for item in items:
        if item.get("isAvailable") and item.get("name") in wanted and item["name"] not in found:
            found[item["name"]] = item["udid"]
for name in wanted:
    if name in found:
        print(found[name] + "\t" + name)
PY
while IFS=$'\t' read -r EXTRA_UDID EXTRA_NAME; do
  [ -n "${EXTRA_UDID:-}" ] || continue
  if [ "$EXTRA_UDID" = "$UDID" ]; then
    continue
  fi
  xcrun simctl shutdown "$UDID" || true
  xcrun simctl boot "$EXTRA_UDID" || true
  xcrun simctl bootstatus "$EXTRA_UDID" -b
  xcrun simctl ui "$EXTRA_UDID" appearance light || true
  xcrun simctl install "$EXTRA_UDID" "$APP"
  xcrun simctl status_bar "$EXTRA_UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 || true
  slug=$(printf '%s' "$EXTRA_NAME" | tr ' ' '-' | tr -d '()')
  xcrun simctl terminate "$EXTRA_UDID" com.tradergoods.madewithlove || true
  xcrun simctl launch "$EXTRA_UDID" com.tradergoods.madewithlove -screenshot home
  sleep 8
  xcrun simctl io "$EXTRA_UDID" screenshot "$OUT/home-$slug.png"
  xcrun simctl shutdown "$EXTRA_UDID" || true
done < "$RUNNER_TEMP/truefoods-extra-devices.txt"

xcrun simctl shutdown "$UDID" || true

# Store screenshots come from a Release build, so the TestFlight color samples are absent.
REL="${RUNNER_TEMP:-/tmp}/truefoods-review"
python3 - << 'PY' > "$RUNNER_TEMP/truefoods-review-devices.txt"
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
                ["xcrun", "simctl", "create", "TrueFoods " + name, ident, runtime["identifier"]],
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
        print("iPhone simulators:", ", ".join(sorted(found)), file=sys.stderr)
        sys.exit("no " + kind + " inch iPhone simulator")
    print(kind + "\t" + chosen[1] + "\t" + chosen[0])
PY
REVIEW_LINE=$(head -n 1 "$RUNNER_TEMP/truefoods-review-devices.txt")
REVIEW_UDID=$(printf '%s' "$REVIEW_LINE" | cut -f2)
xcodebuild \
  -project "$PROJ" \
  -scheme TrueFoods \
  -configuration Release \
  -destination "platform=iOS Simulator,id=$REVIEW_UDID" \
  -derivedDataPath "$REL" \
  CODE_SIGNING_ALLOWED=NO \
  build
RELAPP="$(find "$REL" -path '*Release-iphonesimulator/TrueFoods.app' -print -quit)"
test -n "$RELAPP"
while IFS=$'\t' read -r KIND EXTRA_UDID EXTRA_NAME; do
  [ -n "${EXTRA_UDID:-}" ] || continue
  xcrun simctl boot "$EXTRA_UDID" || true
  xcrun simctl bootstatus "$EXTRA_UDID" -b
  xcrun simctl ui "$EXTRA_UDID" appearance light || true
  xcrun simctl install "$EXTRA_UDID" "$RELAPP"
  xcrun simctl status_bar "$EXTRA_UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 || true
  for SHOT in home result score; do
    xcrun simctl terminate "$EXTRA_UDID" com.tradergoods.madewithlove || true
    xcrun simctl launch "$EXTRA_UDID" com.tradergoods.madewithlove -screenshot "$SHOT"
    sleep 10
    FILE="$OUT/review-$KIND-$SHOT.png"
    xcrun simctl io "$EXTRA_UDID" screenshot "$FILE"
    test -s "$FILE"
  done
  xcrun simctl shutdown "$EXTRA_UDID" || true
done < "$RUNNER_TEMP/truefoods-review-devices.txt"
python3 - << PY
import pathlib, struct, sys
out = pathlib.Path("$OUT")
expect = {"67": {(1290, 2796), (1260, 2736)}, "65": {(1284, 2778), (1242, 2688)}}
for kind, sizes in expect.items():
    for shot in ("home", "result", "score"):
        path = out / f"review-{kind}-{shot}.png"
        data = path.read_bytes()
        if data[1:4] != b"PNG":
            sys.exit(path.name + " is not a png")
        width, height = struct.unpack(">II", data[16:24])
        print(path.name, width, height)
        if (width, height) not in sizes:
            sys.exit(f"{path.name} is {width}x{height}, which is not a {kind} inch App Store size")
PY
ls -lh "$OUT"
