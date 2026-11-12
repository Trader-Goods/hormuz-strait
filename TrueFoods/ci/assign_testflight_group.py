#!/usr/bin/env python3
"""Add the uploaded build to TestFlight groups Me and Family & Friends.

Submits the build for TestFlight beta review when the external group needs it.
Does not submit the app for App Store review.
"""

import os
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(__file__))
from prepare_appstore_signing import api, token

GROUP_NAME = "Me"
EXTERNAL_GROUP_ID = "ec01899f-2e43-4eca-80c0-41031d7b61fc"
EXTERNAL_GROUP_NAME = "Family & Friends"
WAIT_SECONDS = 20 * 60
API_HOST = "https://api.appstoreconnect.apple.com"


def require(name):
    if not os.environ.get(name):
        raise SystemExit(f"missing {name}")


def next_path(page):
    link = (page.get("links") or {}).get("next")
    if not link or not link.startswith(API_HOST):
        return None
    return link[len(API_HOST):]


def app_id(auth, bundle):
    query = urllib.parse.urlencode({"filter[bundleId]": bundle, "limit": 5})
    found = api("GET", "/v1/apps?" + query, auth).get("data", [])
    for item in found:
        if item.get("attributes", {}).get("bundleId") == bundle:
            print("app found")
            return item["id"]
    raise SystemExit("app not found")


def find_group(auth, app):
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
    print("creating internal group Me")
    payload = {
        "data": {
            "type": "betaGroups",
            "attributes": {
                "name": GROUP_NAME,
                "isInternalGroup": True,
                "hasAccessToAllBuilds": True,
            },
            "relationships": {
                "app": {"data": {"type": "apps", "id": app}},
            },
        }
    }
    try:
        created = api("POST", "/v1/betaGroups", auth, payload)
    except SystemExit:
        payload["data"]["attributes"].pop("hasAccessToAllBuilds", None)
        created = api("POST", "/v1/betaGroups", auth, payload)
    group = created["data"]["id"]
    print("internal group created")
    try:
        if not group_access(auth, group):
            enable_automatic(auth, group)
    except SystemExit:
        print("automatic distribution was not enabled")
    return group


def add_internal_testers(auth, app, group):
    try:
        users = api("GET", "/v1/users?limit=20", auth, quiet=True).get("data", [])
    except SystemExit:
        print("could not list App Store Connect users")
        print("add yourself to internal group Me if the build does not appear")
        return
    added = 0
    for user in users:
        attributes = user.get("attributes") or {}
        email = attributes.get("username") or ""
        if "@" not in email:
            continue
        try:
            api("POST", "/v1/betaTesters", auth, {
                "data": {
                    "type": "betaTesters",
                    "attributes": {"email": email},
                    "relationships": {
                        "betaGroups": {"data": [{"type": "betaGroups", "id": group}]},
                    },
                }
            }, quiet=True)
            added += 1
        except SystemExit as error:
            if getattr(error, "code", None) not in (409, 422):
                print("a tester could not be added")
    if added:
        print(f"added {added} internal testers")
    else:
        print("internal testers were already on the group or could not be added")


def group_access(auth, group):
    attributes = api("GET", f"/v1/betaGroups/{group}", auth)["data"].get("attributes", {})
    access = attributes.get("hasAccessToAllBuilds")
    print(f"hasAccessToAllBuilds {access}")
    return access is True


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


def beta_state(auth, build):
    payload = api("GET", f"/v1/builds/{build}?include=buildBetaDetail", auth)
    for item in payload.get("included", []):
        if item.get("type") == "buildBetaDetails":
            return item.get("attributes", {}).get("internalBuildState")
    return None


def answer_export(auth, build):
    api("PATCH", f"/v1/builds/{build}", auth, {
        "data": {
            "type": "builds",
            "id": build,
            "attributes": {"usesNonExemptEncryption": False},
        },
    })
    print("export compliance answered")


def group_has_build(auth, group, build):
    path = f"/v1/betaGroups/{group}/relationships/builds?limit=200"
    while path:
        try:
            page = api("GET", path, auth)
        except SystemExit as error:
            if getattr(error, "code", None) == 403:
                return False
            raise
        for item in page.get("data", []):
            if item.get("id") == build:
                return True
        path = next_path(page)
    return False


def build_has_group(auth, build, group):
    path = f"/v1/builds/{build}/relationships/betaGroups?limit=50"
    while path:
        try:
            page = api("GET", path, auth)
        except SystemExit as error:
            if getattr(error, "code", None) == 403:
                return False
            raise
        for item in page.get("data", []):
            if item.get("id") == group:
                return True
        path = next_path(page)
    return False


def enable_automatic(auth, group):
    api("PATCH", f"/v1/betaGroups/{group}", auth, {
        "data": {
            "type": "betaGroups",
            "id": group,
            "attributes": {"hasAccessToAllBuilds": True},
        },
    })
    print("automatic distribution enabled for internal group Me")


def link_group(auth, build, group):
    try:
        api("POST", f"/v1/builds/{build}/relationships/betaGroups", auth, {
            "data": [{"type": "betaGroups", "id": group}],
        })
    except SystemExit as error:
        code = getattr(error, "code", None)
        if code == 409:
            print("build already in the internal group")
            return
        if code == 422:
            return
        raise
    print("build added to internal group Me")


def assigned(auth, group, build, automatic):
    if group_has_build(auth, group, build) or build_has_group(auth, build, group):
        print("build added to internal group Me")
        return True
    if automatic:
        print("build available to internal group Me")
        print("the group receives every build, so a manual add is rejected")
        return True
    return False


def submit_beta_review(auth, build_id):
    query = urllib.parse.urlencode({"filter[build]": build_id, "limit": 5})
    try:
        found = api("GET", "/v1/betaAppReviewSubmissions?" + query, auth).get("data", [])
    except SystemExit:
        found = []
    for item in found:
        state = (item.get("attributes") or {}).get("betaReviewState") or ""
        print(f"beta review state {state}")
        if state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"):
            print("TestFlight beta review already submitted")
            return True
    try:
        api("POST", "/v1/betaAppReviewSubmissions", auth, {
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}},
                },
            }
        })
    except SystemExit as error:
        if getattr(error, "code", None) == 409:
            print("TestFlight beta review already submitted")
            return True
        print("TestFlight beta review was not submitted")
        return False
    print("submitted for TestFlight beta review")
    return True


def link_external_group(auth, build_id):
    print("adding build to external group " + EXTERNAL_GROUP_NAME)
    try:
        api("POST", f"/v1/builds/{build_id}/relationships/betaGroups", auth, {
            "data": [{"type": "betaGroups", "id": EXTERNAL_GROUP_ID}],
        })
    except SystemExit as error:
        code = getattr(error, "code", None)
        if code == 409:
            print("build already in external group " + EXTERNAL_GROUP_NAME)
            return True
        if code == 422:
            print(f"external group link returned {code}")
            if group_has_build(auth, EXTERNAL_GROUP_ID, build_id) or build_has_group(auth, build_id, EXTERNAL_GROUP_ID):
                print("build added to external group " + EXTERNAL_GROUP_NAME)
                return True
            return False
        raise
    print("build added to external group " + EXTERNAL_GROUP_NAME)
    return True


def distribute_external(auth, build_id):
    if link_external_group(auth, build_id):
        return
    submitted = submit_beta_review(auth, build_id)
    if link_external_group(auth, build_id):
        return
    if submitted:
        print("Family & Friends will receive this build after TestFlight beta review")
        return
    raise SystemExit("build was not added to Family & Friends and beta review was not submitted")


def main():
    for name in ("KEY_PATH", "KID", "ISS", "BUNDLE_ID", "BUILD_NUMBER"):
        require(name)
    number = os.environ["BUILD_NUMBER"]
    auth = token()
    app = app_id(auth, os.environ["BUNDLE_ID"])
    group = find_group(auth, app)
    add_internal_testers(auth, app, group)
    deadline = time.time() + WAIT_SECONDS
    build_id = None
    while time.time() < deadline:
        auth = token()
        build_id, state = find_build(auth, app, number)
        if build_id:
            print(f"build {number} visible, state {state}")
            if state == "INVALID":
                raise SystemExit("uploaded build is invalid")
            if state == "VALID":
                break
        else:
            print(f"waiting for build {number}")
        time.sleep(20)
    if not build_id:
        raise SystemExit("uploaded build did not appear")

    internal = beta_state(auth, build_id)
    print(f"internal build state {internal}")
    if internal == "MISSING_EXPORT_COMPLIANCE":
        answer_export(auth, build_id)

    if assigned(auth, group, build_id, False):
        distribute_external(auth, build_id)
        return

    automatic = group_access(auth, group)
    if not automatic:
        enable_automatic(auth, group)
        automatic = True

    link_group(auth, build_id, group)
    if assigned(auth, group, build_id, automatic):
        distribute_external(auth, build_id)
        return
    raise SystemExit("build was not added to internal group Me")


if __name__ == "__main__":
    main()
