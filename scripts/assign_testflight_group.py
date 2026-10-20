#!/usr/bin/env python3
"""Add the uploaded build to the internal TestFlight group named Me.

Does not submit the app for App Store review.
"""

import os
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(__file__))
from prepare_appstore_signing import api, token

GROUP_NAME = "Me"
WAIT_SECONDS = 20 * 60


def require(name):
    if not os.environ.get(name):
        raise SystemExit(f"missing {name}")


def app_id(auth, bundle):
    query = urllib.parse.urlencode({"filter[bundleId]": bundle, "limit": 5})
    found = api("GET", "/v1/apps?" + query, auth).get("data", [])
    for item in found:
        if item.get("attributes", {}).get("bundleId") == bundle:
            print("app found")
            return item["id"]
    raise SystemExit("app not found")


def group_id(auth, app):
    query = urllib.parse.urlencode({"filter[app]": app, "limit": 50})
    found = api("GET", "/v1/betaGroups?" + query, auth).get("data", [])
    names = []
    for item in found:
        attributes = item.get("attributes", {})
        name = attributes.get("name") or ""
        names.append(name)
        if name == GROUP_NAME and attributes.get("isInternalGroup") is True:
            print("internal group found")
            return item["id"]
    print("internal group Me was not found")
    print("groups:", ", ".join(names) if names else "(none)")
    raise SystemExit(1)


def find_build(auth, app, number):
    query = urllib.parse.urlencode({
        "filter[app]": app,
        "filter[version]": number,
        "sort": "-uploadedDate",
        "limit": 5,
    })
    found = api("GET", "/v1/builds?" + query, auth).get("data", [])
    for item in found:
        attributes = item.get("attributes", {})
        if str(attributes.get("version")) == str(number):
            return item["id"], attributes.get("processingState")
    return None, None


def assign(auth, group, build):
    try:
        api("POST", f"/v1/betaGroups/{group}/relationships/builds", auth, {
            "data": [{"type": "builds", "id": build}],
        })
    except SystemExit as error:
        if getattr(error, "code", None) == 409:
            print("build already in the internal group")
            return
        raise
    print("build added to internal group Me")


def main():
    for name in ("KEY_PATH", "KID", "ISS", "BUNDLE_ID", "BUILD_NUMBER"):
        require(name)
    number = os.environ["BUILD_NUMBER"]
    auth = token()
    app = app_id(auth, os.environ["BUNDLE_ID"])
    group = group_id(auth, app)
    deadline = time.time() + WAIT_SECONDS
    build_id = None
    while time.time() < deadline:
        auth = token()
        build_id, state = find_build(auth, app, number)
        if build_id:
            print(f"build {number} visible, state {state}")
            if state == "INVALID":
                raise SystemExit("uploaded build is invalid")
            break
        print(f"waiting for build {number}")
        time.sleep(20)
    if not build_id:
        raise SystemExit("uploaded build did not appear")
    assign(auth, group, build_id)


if __name__ == "__main__":
    main()
