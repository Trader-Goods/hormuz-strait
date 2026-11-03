#!/bin/bash
# Build the iOS simulator app and capture the five marketing screens.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/artifacts/screenshots}"
DERIVED="${DERIVED_DATA:-$ROOT/build/sim}"
mkdir -p "$OUT/raw"

if [ -z "${APP_PATH:-}" ]; then
  xcodebuild \
    -project "$ROOT/Contractor.xcodeproj" \
    -scheme Contractor \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    build
  APP_PATH="$(find "$DERIVED/Build/Products" -type d -name 'Contractor.app' | head -1)"
fi
test -d "$APP_PATH"
BUNDLE="com.tradergoods.contractor"
echo "App: $APP_PATH"

pick_runtime() {
  python3 - <<'PY'
import json, subprocess
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
rows = [r for r in data["runtimes"] if r.get("isAvailable") and "iOS" in r.get("name", "")]
if not rows:
    raise SystemExit("no iOS runtime")
print(rows[-1]["identifier"])
PY
}

pick_device() {
  python3 - "$1" <<'PY'
import json, subprocess, sys
want = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))
names = [d["name"] for d in data["devicetypes"]]
prefs = {
    "6.7": ["iPhone 16 Plus", "iPhone 15 Plus", "iPhone 15 Pro Max", "iPhone 14 Plus", "iPhone 14 Pro Max", "iPhone 16 Pro Max", "iPhone 17 Pro Max"],
    "6.5": ["iPhone 11 Pro Max", "iPhone XS Max"],
}[want]
for name in prefs:
    if name in names:
        print(name)
        raise SystemExit(0)
print("MISSING", file=sys.stderr)
raise SystemExit(1)
PY
}

grab() {
  local udid="$1" shot="$2" dest="$3" try
  for try in 1 2 3 4; do
    SIMCTL_CHILD_SCREENSHOT="$shot" xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE" >/dev/null
    xcrun simctl openurl "$udid" "contractorpros://screenshot" || true
    if [ "$shot" = "map" ]; then sleep 10; else sleep 6; fi
    xcrun simctl io "$udid" screenshot "$dest"
    if python3 - "$dest" <<'PY'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
sample = im.crop((w // 8, h // 6, 7 * w // 8, 5 * h // 6)).resize((60, 80))
stat = ImageStat.Stat(sample)
mean = sum(stat.mean) / 3
spread = sum(stat.stddev) / 3
# A blank launch screen is flat white or flat black. A real screen has color variation.
raise SystemExit(0 if 18 < mean < 248 and spread > 12 else 1)
PY
    then
      echo "captured $dest"
      return 0
    fi
    echo "blank frame for $shot, try $try"
  done
  echo "kept last frame for $dest"
}

boot_one() {
  local label="$1"
  local name
  if ! name="$(pick_device "$label")"; then
    echo "No $label device type"
    return 1
  fi
  local runtime udid
  runtime="$(pick_runtime)"
  echo "Creating $label on $name ($runtime)"
  udid="$(xcrun simctl create "Contractor-$label" "$name" "$runtime")"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --batteryState charged \
    --batteryLevel 100 \
    --cellularMode active \
    --cellularBars 4 \
    || true
  xcrun simctl privacy "$udid" grant location "$BUNDLE" || true
  xcrun simctl privacy "$udid" grant photos "$BUNDLE" || true
  xcrun simctl location "$udid" set 41.562,-83.654 || true
  xcrun simctl install "$udid" "$APP_PATH"
  local shot dest try
  xcrun simctl ui "$udid" content_size large || true
  for shot in welcome home map post pay; do
    grab "$udid" "$shot" "$OUT/raw/${label}-${shot}.png"
  done
  if [ "$label" = "6.7" ]; then
    xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large \
      || xcrun simctl ui "$udid" content_size AX5 \
      || true
    sleep 2
    for shot in welcome home pay; do
      grab "$udid" "$shot" "$OUT/raw/large-${shot}.png"
    done
  fi
  xcrun simctl shutdown "$udid" || true
  xcrun simctl delete "$udid" || true
}

RUNTIME_OK=0
boot_one 6.7 && RUNTIME_OK=1
boot_one 6.5 || echo "6.5 device unavailable; marketing frames will scale the 6.7 captures"
test "$RUNTIME_OK" = 1
python3 "$ROOT/scripts/marketing_frames.py" "$OUT/raw" "$OUT/marketing"
echo "Screenshots in $OUT"
