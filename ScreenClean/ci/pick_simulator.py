#!/usr/bin/env python3
"""Print the UDID of one available iPhone simulator."""

import json
import subprocess
import sys

preferred = [
    "iPhone 16",
    "iPhone 16 Pro",
    "iPhone 15",
    "iPhone SE (3rd generation)",
    "iPhone 14",
]

raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
data = json.loads(raw)
devices = []
for runtime, items in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for item in items:
        if item.get("isAvailable") and str(item.get("name", "")).startswith("iPhone"):
            devices.append(item)


def rank(item):
    name = item.get("name", "")
    if name in preferred:
        return preferred.index(name)
    return 50


devices.sort(key=rank)
if not devices:
    sys.exit("no iPhone simulator")
print(devices[0]["udid"])
