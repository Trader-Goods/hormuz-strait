#!/bin/bash
# Run TrueFoods unit tests on one simulator, with a hard stop if boot or xcodebuild hangs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UDID="$(python3 "$ROOT/TrueFoods/ci/pick_simulator.py")"

# xcodebuild boots the simulator itself. A separate bootstatus wait can sit forever
# on these runners, so the only hard stop is the test command.
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
deadline = time.time() + 20 * 60
while proc.poll() is None:
    if time.time() > deadline:
        proc.kill()
        subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)
        sys.exit("unit tests timed out after 20 minutes")
    time.sleep(5)
sys.exit(proc.returncode)
PY
