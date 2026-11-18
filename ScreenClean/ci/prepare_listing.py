#!/usr/bin/env python3
"""Fill Screen Clean version 1.0. Does not submit it for App Review."""

import importlib.util
import json
import os
import pathlib
import urllib.parse

APP_BUNDLE = "com.tradergoods.screenclean"
SUPPORT = "https://trader-goods.github.io/hormuz-strait/screenclean.html"
PRIVACY = "https://trader-goods.github.io/hormuz-strait/screenclean-privacy.html"
DESCRIPTION = """Screen Clean turns the glass black for one minute so you can see what you are wiping.

Press Clean. The screen goes pure black and the brightness drops. Fingerprint oil reflects the light in the room, and dust shows up as a bright speck. A bright page hides both. Wipes do not tap or swipe anything. The phone stays awake. After 60 seconds your previous brightness comes back. Hold the black screen to stop early.

Tilt the phone under a lamp and use a soft, dry cloth. Do not spray liquid on the glass. The app does not wash the screen for you.

No account. No ads. No network. Nothing is collected."""
KEYWORDS = "screen clean,smudge,fingerprint,wipe,glass,dust,cloth,display,oled"
SUBTITLE = "See every smudge. Wipe."
SHOTS = {
    "APP_IPHONE_67": ["review-67-home.png", "review-67-clean.png"],
    "APP_IPHONE_65": ["review-65-home.png", "review-65-clean.png"],
}

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("signing", ROOT / "ScreenClean/ci/prepare_appstore_signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def call(auth, method, path, body=None):
    return signing.api(method, path, auth, body)


def soft(auth, method, path, body=None):
    try:
        return signing.api(method, path, auth, body)
    except SystemExit as error:
        print(json.dumps(getattr(error, "payload", {}) or {}, sort_keys=True)[:1500])
        return None


def app_id(auth):
    query = urllib.parse.urlencode({"filter[bundleId]": APP_BUNDLE, "limit": 5})
    for item in call(auth, "GET", "/v1/apps?" + query).get("data", []):
        if item.get("attributes", {}).get("bundleId") == APP_BUNDLE:
            print("app", item["id"], item.get("attributes", {}).get("name"))
            return item["id"]
    raise SystemExit("app record was not found")


def version(auth, app):
    found = call(auth, "GET", f"/v1/apps/{app}/appStoreVersions?filter[platform]=IOS&limit=10")
    for item in found.get("data", []):
        if item.get("attributes", {}).get("versionString") == "1.0":
            return item
    created = call(auth, "POST", "/v1/appStoreVersions", {
        "data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": "1.0", "releaseType": "MANUAL", "copyright": "2026 Trader Goods"},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}},
        }
    })
    return created["data"]


def patch(auth, path, kind, resource_id, attributes):
    try:
        return call(auth, "PATCH", path, {"data": {"type": kind, "id": resource_id, "attributes": attributes}})
    except SystemExit as error:
        print(json.dumps(getattr(error, "payload", {}) or {})[:1500])
        raise


def upload_screenshots(auth, localization_id, folder):
    if not folder.is_dir():
        print("no screenshot folder")
        return
    existing = call(auth, "GET", f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets?limit=20")
    sets = {item.get("attributes", {}).get("screenshotDisplayType"): item["id"] for item in existing.get("data", [])}
    for display, names in SHOTS.items():
        paths = [folder / name for name in names]
        if not all(path.is_file() for path in paths):
            print("missing", display)
            continue
        set_id = sets.get(display)
        if not set_id:
            created = call(auth, "POST", "/v1/appScreenshotSets", {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": display},
                    "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": localization_id}}},
                }
            })
            set_id = created["data"]["id"]
        have = call(auth, "GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=10")
        have_names = {(item.get("attributes") or {}).get("fileName") for item in have.get("data", [])}
        for path in paths:
            if path.name in have_names:
                print("already uploaded", path.name)
                continue
            data = path.read_bytes()
            reserved = call(auth, "POST", "/v1/appScreenshots", {
                "data": {
                    "type": "appScreenshots",
                    "attributes": {"fileName": path.name, "fileSize": len(data)},
                    "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
                }
            })
            for operation in reserved["data"]["attributes"]["uploadOperations"]:
                offset = int(operation.get("offset") or 0)
                length = int(operation.get("length") or len(data))
                headers = {item["name"]: item["value"] for item in operation.get("requestHeaders", [])}
                import urllib.request
                request = urllib.request.Request(operation["url"], data=data[offset:offset + length], method=operation.get("method", "PUT"), headers=headers)
                with urllib.request.urlopen(request, timeout=120) as response:
                    response.read()
            call(auth, "PATCH", f"/v1/appScreenshots/{reserved['data']['id']}", {
                "data": {"type": "appScreenshots", "id": reserved["data"]["id"], "attributes": {"uploaded": True}}
            })
            print("uploaded", display, path.name)


def main():
    if len(DESCRIPTION) > 4000 or len(KEYWORDS) > 100 or len(SUBTITLE) > 30:
        raise SystemExit("metadata is over the length limit")
    auth = signing.token()
    app = app_id(auth)
    info = call(auth, "GET", f"/v1/apps/{app}/appInfos")["data"][0]
    soft(auth, "PATCH", f"/v1/appInfos/{info['id']}", {
        "data": {
            "type": "appInfos",
            "id": info["id"],
            "relationships": {"primaryCategory": {"data": {"type": "appCategories", "id": "UTILITIES"}}},
        }
    })
    locales = call(auth, "GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations")
    locale = next((item for item in locales.get("data", []) if str(item.get("attributes", {}).get("locale", "")).startswith("en")), None)
    if locale:
        patch(auth, f"/v1/appInfoLocalizations/{locale['id']}", "appInfoLocalizations", locale["id"], {
            "subtitle": SUBTITLE,
            "privacyPolicyUrl": PRIVACY,
        })
    store = version(auth, app)
    copy_list = call(auth, "GET", f"/v1/appStoreVersions/{store['id']}/appStoreVersionLocalizations")
    copy = next((item for item in copy_list.get("data", []) if str(item.get("attributes", {}).get("locale", "")).startswith("en")), copy_list["data"][0])
    patch(auth, f"/v1/appStoreVersionLocalizations/{copy['id']}", "appStoreVersionLocalizations", copy["id"], {
        "description": DESCRIPTION,
        "keywords": KEYWORDS,
        "supportUrl": SUPPORT,
    })
    print("listing text saved")
    folder = pathlib.Path(os.environ.get("SHOTS", "artifacts/screenshots"))
    upload_screenshots(auth, copy["id"], folder)
    print("LISTING_READY")
    print("not submitted for review")


if __name__ == "__main__":
    main()
