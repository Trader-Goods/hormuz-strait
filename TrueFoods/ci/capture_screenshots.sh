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

xcrun simctl shutdown "$UDID" || true
ls -lh "$OUT"
