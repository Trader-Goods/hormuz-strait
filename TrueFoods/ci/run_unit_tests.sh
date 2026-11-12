#!/bin/bash
# Run TrueFoods unit tests on one simulator, with a hard stop if boot or xcodebuild hangs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UDID="$(python3 "$ROOT/TrueFoods/ci/pick_simulator.py")"

xcrun simctl boot "$UDID" || true

python3 - "$UDID" << 'PY'
import subprocess, sys, time
udid = sys.argv[1]
proc = subprocess.Popen(["xcrun", "simctl", "bootstatus", udid, "-b"])
deadline = time.time() + 240
while proc.poll() is None:
    if time.time() > deadline:
        proc.kill()
        sys.exit("simulator boot timed out after 4 minutes")
    time.sleep(2)
if proc.returncode != 0:
    sys.exit(proc.returncode)
PY

python3 - "$UDID" "$ROOT" << 'PY'
import subprocess, sys, time
udid, root = sys.argv[1], sys.argv[2]
cmd = [
    "xcodebuild", "test",
    "-project", f"{root}/TrueFoods/TrueFoods.xcodeproj",
    "-scheme", "TrueFoods",
    "-destination", f"platform=iOS Simulator,id={udid}",
    "CODE_SIGNING_ALLOWED=NO",
]
proc = subprocess.Popen(cmd)
deadline = time.time() + 12 * 60
while proc.poll() is None:
    if time.time() > deadline:
        proc.kill()
        sys.exit("unit tests timed out after 12 minutes")
    time.sleep(5)
sys.exit(proc.returncode)
PY
