#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UDID="$(python3 "$ROOT/ScreenClean/ci/pick_simulator.py")"

python3 - "$UDID" "$ROOT" << 'PY'
import subprocess, sys, time
udid, root = sys.argv[1], sys.argv[2]
cmd = [
    "xcodebuild", "test",
    "-project", f"{root}/ScreenClean/ScreenClean.xcodeproj",
    "-scheme", "ScreenClean",
    "-destination", f"platform=iOS Simulator,id={udid}",
    "CODE_SIGNING_ALLOWED=NO",
]
proc = subprocess.Popen(cmd)
deadline = time.time() + 20 * 60
while proc.poll() is None:
    if time.time() > deadline:
        proc.kill()
        subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)
        sys.exit("unit tests timed out after 20 minutes")
    time.sleep(5)
sys.exit(proc.returncode)
PY
