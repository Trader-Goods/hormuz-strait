#!/usr/bin/env python3
"""Fill TrueFoods version 1.0 and submit that build for App Store review.

The paid-apps agreement is left as it is. This app is free.
"""

import importlib.util
import json
import os
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request

APP = "6833977562"
SUPPORT = "https://trader-goods.github.io/hormuz-strait/truefoods.html"
PRIVACY = "https://trader-goods.github.io/hormuz-strait/truefoods-privacy.html"
DESCRIPTION = """TrueFoods scores packaged food from 0 to 100 in plain words.

Scan a barcode or search for a product sold in the United States. The score starts at 100 and goes down for dyes, additives, sugar, salt, and processing. A flagged ingredient, such as Red 40, turns the card red. Wine, beer, and spirits are capped so they are not scored like groceries. If the ingredient list is missing, the card stays gray instead of showing a made-up perfect score.

What you can do:
• Scan a barcode or a label with the camera
• Search grocery products sold in the United States
• Read a short list of what raised or lowered the score
• Flag ingredients you avoid and see them in red
• Save favorites and look back at recent scans
• See a recall notice when openFDA has one

The camera, favorites, and recent scans stay on your iPhone. There is no account, no ad, and no payment.

TrueFoods is a guide to the label, not medical advice. Check the package if you have an allergy."""
KEYWORDS = "barcode,ingredients,additives,food score,grocery,nutrition,label,scan,pantry,recall"
SUBTITLE = "Scan food. See the score."
NOTES = (
    "No account is required. The app is free. To review, open Look, search for almond milk, "
    "and open a result. The score and the plain-language notes appear after the product loads. "
    "Scan uses the camera for a barcode. Lookups use Open Food Facts and, when needed, USDA "
    "FoodData Central. Recall checks use openFDA. Photos and saved foods stay on the device. "
    "This build has no color-sample or test products on the home screen. TrueFoods is not medical advice."
)
SHOTS = {
    "APP_IPHONE_67": ["review-67-home.png", "review-67-result.png", "review-67-score.png"],
    "APP_IPHONE_65": ["review-65-home.png", "review-65-result.png", "review-65-score.png"],
}

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("signing", ROOT / "TrueFoods/ci/prepare_appstore_signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
api = signing.api


class Blocker(SystemExit):
    pass


def fail(message):
    print("BLOCKER: " + message)
    raise Blocker(1)


def call(auth, method, path, body=None):
    try:
        return api(method, path, auth, body)
    except SystemExit as error:
        payload = getattr(error, "payload", {}) or {}
        detail = json.dumps(payload, sort_keys=True)[:2000]
        print(f"BLOCKER: {method} {path.split('?')[0]} failed: {detail}")
        raise Blocker(1) from error


def soft(auth, method, path, body=None):
    try:
        return api(method, path, auth, body)
    except SystemExit as error:
        payload = getattr(error, "payload", {}) or {}
        print(f"{method} {path.split('?')[0]} returned {getattr(error, 'code', '?')}")
        print(json.dumps(payload, sort_keys=True)[:2000])
        return None


def page_live(url):
    request = urllib.request.Request(url, headers={"User-Agent": "TrueFoods/1.0"})
    for _ in range(12):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                if response.status == 200 and b"TrueFoods" in body and b"support@tradergoods.us" in body:
                    print("page live", url)
                    return
        except Exception as error:
            print("waiting for", url, error)
        time.sleep(15)
    fail(f"support page is not live yet: {url}")


def patch_attributes(auth, path, resource_type, resource_id, attributes):
    attrs = dict(attributes)
    last = ""
    for _ in range(10):
        body = {"data": {"type": resource_type, "id": resource_id, "attributes": attrs}}
        try:
            return api("PATCH", path, auth, body)
        except SystemExit as error:
            payload = getattr(error, "payload", {}) or {}
            last = json.dumps(payload)
            print(last[:1500])
            dropped = [key for key in list(attrs) if key in last and any(word in last.lower() for word in ("unknown", "not a valid", "isn't valid", "does not exist", "not supported"))]
            if not dropped:
                fail(f"could not update {resource_type}: {last[:1500]}")
            for key in dropped:
                attrs.pop(key, None)
                print("dropped", key)
    fail(f"could not update {resource_type}: {last[:1500]}")


def find_version(auth):
    found = call(auth, "GET", f"/v1/apps/{APP}/appStoreVersions?filter[platform]=IOS&limit=10")
    for item in found.get("data", []):
        if item.get("attributes", {}).get("versionString") == "1.0":
            return item
    created = call(auth, "POST", "/v1/appStoreVersions", {
        "data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": "1.0", "releaseType": "MANUAL", "copyright": "2026 Trader Goods"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}},
        }
    })
    return created["data"]


def localization(auth, version_id):
    found = call(auth, "GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    for item in found.get("data", []):
        if item.get("attributes", {}).get("locale") in ("en-US", "en-GB", None) or True:
            if item.get("attributes", {}).get("locale", "en-US").startswith("en"):
                return item
    if found.get("data"):
        return found["data"][0]
    created = call(auth, "POST", "/v1/appStoreVersionLocalizations", {
        "data": {
            "type": "appStoreVersionLocalizations",
            "attributes": {"locale": "en-US"},
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}},
        }
    })
    return created["data"]


def app_info(auth):
    found = call(auth, "GET", f"/v1/apps/{APP}/appInfos?include=appInfoLocalizations")
    return found["data"][0]


def set_categories(auth, info_id):
    body = {
        "data": {
            "type": "appInfos",
            "id": info_id,
            "relationships": {
                "primaryCategory": {"data": {"type": "appCategories", "id": "FOOD_AND_DRINK"}},
                "secondaryCategory": {"data": {"type": "appCategories", "id": "HEALTH_AND_FITNESS"}},
            },
        }
    }
    result = soft(auth, "PATCH", f"/v1/appInfos/{info_id}", body)
    if result is None:
        soft(auth, "PATCH", f"/v1/appInfos/{info_id}", {
            "data": {
                "type": "appInfos",
                "id": info_id,
                "relationships": {
                    "primaryCategory": {"data": {"type": "appCategories", "id": "FOOD_AND_DRINK"}},
                },
            }
        })


def set_age_rating(auth, info_id):
    found = call(auth, "GET", f"/v1/appInfos/{info_id}/ageRatingDeclaration")
    item = found["data"]
    current = item.get("attributes") or {}
    print("age rating fields", ", ".join(sorted(current)))
    bool_true = {"healthOrWellnessTopics"}
    bool_false = {
        "advertising", "ageAssurance", "gambling", "lootBox", "messagingAndChat",
        "parentalControls", "socialMedia", "socialMediaAgeRestricted",
        "unrestrictedWebAccess", "userGeneratedContent",
    }
    attrs = {}
    for key, value in current.items():
        if key in ("developerAgeRatingInfoUrl", "gracRatingClassificationNumber", "ageRatingOverride"):
            continue
        if key == "alcoholTobaccoOrDrugUseOrReferences":
            attrs[key] = "INFREQUENT_OR_MILD"
        elif key == "kidsAgeBand":
            attrs[key] = None
        elif isinstance(value, bool) or key in bool_true or key in bool_false:
            attrs[key] = key in bool_true
        else:
            attrs[key] = "NONE"
    for key in bool_false:
        attrs.setdefault(key, False)
    for key in bool_true:
        attrs.setdefault(key, True)
    path = f"/v1/ageRatingDeclarations/{item['id']}"
    seen = set()
    for _ in range(12):
        signature = tuple(sorted((key, repr(value)) for key, value in attrs.items()))
        if signature in seen:
            fail("age rating answers did not settle: " + ", ".join(sorted(attrs)))
        seen.add(signature)
        body = {"data": {"type": "ageRatingDeclarations", "id": item["id"], "attributes": attrs}}
        try:
            api("PATCH", path, auth, body)
            print("age rating saved")
            return
        except SystemExit as error:
            payload = getattr(error, "payload", {}) or {}
            text = json.dumps(payload)
            print(text[:1500])
            changed = False
            for item in payload.get("errors", []):
                pointer = ((item.get("source") or {}).get("pointer") or "").rsplit("/", 1)[-1]
                detail = item.get("detail") or ""
                code = item.get("code") or ""
                if not pointer or pointer not in attrs:
                    continue
                if "Expected a BOOLEAN" in detail:
                    attrs[pointer] = False
                    changed = True
                elif "TYPE" in code or "not a valid" in detail.lower():
                    attrs[pointer] = "NONE" if pointer != "alcoholTobaccoOrDrugUseOrReferences" else "INFREQUENT_OR_MILD"
                    changed = True
                elif any(word in detail.lower() for word in ("unknown", "does not exist", "not supported", "read-only", "read only", "cannot be modified", "cannot be set")):
                    attrs.pop(pointer, None)
                    changed = True
                else:
                    for name in __import__("re").findall(r"'([A-Za-z][A-Za-z0-9]*)'", detail):
                        if name in attrs and "cannot" in detail.lower():
                            attrs.pop(name, None)
                            changed = True
                            print("dropped", name)
                            break
                if pointer:
                    print("age rating field", pointer, "->", attrs.get(pointer, "dropped"))
            if changed:
                continue
            fail(f"could not save the age rating: {text[:1500]}")
    fail("could not save the age rating")


def set_price(auth):
    points = []
    path = f"/v1/apps/{APP}/appPricePoints?filter[territory]=USA&limit=200"
    for _ in range(8):
        page = soft(auth, "GET", path)
        if not page:
            return
        points.extend(page.get("data", []))
        path = (page.get("links") or {}).get("next")
        if path and path.startswith(signing.API):
            path = path[len(signing.API):]
        else:
            break
    free = next((item for item in points if str((item.get("attributes") or {}).get("customerPrice")) in ("0", "0.0", "0.00")), None)
    if not free:
        print("BLOCKER: no free USA price point was returned")
        return
    result = soft(auth, "POST", "/v1/appPriceSchedules", {
        "data": {
            "type": "appPriceSchedules",
            "relationships": {
                "app": {"data": {"type": "apps", "id": APP}},
                "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]},
            },
        },
        "included": [{
            "type": "appPrices",
            "id": "${free}",
            "attributes": {"startDate": None},
            "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}},
        }],
    })
    if result is not None:
        print("price set to free")
    territories = soft(auth, "GET", "/v1/territories?limit=200")
    if not territories:
        return
    ids = [{"type": "territories", "id": item["id"]} for item in territories.get("data", [])]
    availability = soft(auth, "POST", "/v1/appAvailabilities", {
        "data": {
            "type": "appAvailabilities",
            "attributes": {"availableInNewTerritories": True},
            "relationships": {
                "app": {"data": {"type": "apps", "id": APP}},
                "availableTerritories": {"data": ids},
            },
        }
    })
    if availability is not None:
        print("available in territories", len(ids))


def iris(auth, method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        "https://appstoreconnect.apple.com/iris/v1" + path,
        data=data,
        method=method,
        headers={"Authorization": "Bearer " + auth, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read().decode()
        print(f"IRIS {method} {path.split('?')[0]} failed: {error.code}")
        print(raw[:2000])
        failure = SystemExit(1)
        failure.code = error.code
        failure.payload = json.loads(raw) if raw[:1] in "{[" else {"raw": raw[:2000]}
        raise failure


def declare_privacy(auth):
    """The food name or barcode is sent to look up the product. It is not linked to a person."""
    try:
        existing = iris(auth, "GET", f"/apps/{APP}/dataUsages?limit=50")
    except SystemExit:
        existing = {"data": []}
    already = False
    for item in existing.get("data", []):
        relations = item.get("relationships") or {}
        category = ((relations.get("category") or {}).get("data") or {}).get("id")
        purpose = ((relations.get("purpose") or {}).get("data") or {}).get("id")
        protection = ((relations.get("dataProtection") or {}).get("data") or {}).get("id")
        if category == "SEARCH_HISTORY" and purpose == "APP_FUNCTIONALITY" and protection == "DATA_NOT_LINKED_TO_YOU":
            already = True
    if not already:
        try:
            iris(auth, "POST", "/appDataUsages", {
                "data": {
                    "type": "appDataUsages",
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": APP}},
                        "category": {"data": {"type": "appDataUsageCategories", "id": "SEARCH_HISTORY"}},
                        "purpose": {"data": {"type": "appDataUsagePurposes", "id": "APP_FUNCTIONALITY"}},
                        "dataProtection": {"data": {"type": "appDataUsageDataProtections", "id": "DATA_NOT_LINKED_TO_YOU"}},
                    },
                }
            })
            print("privacy usage saved")
        except SystemExit as error:
            if getattr(error, "code", None) not in (409, 422):
                print("privacy usage was not saved")
    try:
        state = iris(auth, "GET", f"/apps/{APP}/dataUsagePublishState")
        state_id = state["data"]["id"]
        iris(auth, "PATCH", f"/appDataUsagesPublishState/{state_id}", {
            "data": {
                "type": "appDataUsagesPublishState",
                "id": state_id,
                "attributes": {"published": True},
            }
        })
        print("privacy answers published")
    except SystemExit:
        print("privacy answers were saved but not published")


def upload_bytes(operations, data):
    for operation in operations:
        offset = int(operation.get("offset") or 0)
        length = int(operation.get("length") or len(data))
        headers = {item["name"]: item["value"] for item in operation.get("requestHeaders", [])}
        request = urllib.request.Request(
            operation["url"],
            data=data[offset:offset + length],
            method=operation.get("method", "PUT"),
            headers=headers,
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            response.read()


def upload_screenshots(auth, localization_id, folder):
    existing = call(auth, "GET", f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets?limit=20")
    sets = {item.get("attributes", {}).get("screenshotDisplayType"): item["id"] for item in existing.get("data", [])}
    for display, names in SHOTS.items():
        set_id = sets.get(display)
        if not set_id:
            created = call(auth, "POST", "/v1/appScreenshotSets", {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": display},
                    "relationships": {
                        "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": localization_id}}
                    },
                }
            })
            set_id = created["data"]["id"]
        have = call(auth, "GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=20")
        have_names = {(item.get("attributes") or {}).get("fileName") for item in have.get("data", [])}
        for name in names:
            if name in have_names:
                print("screenshot already uploaded", name)
                continue
            data = (folder / name).read_bytes()
            reserved = call(auth, "POST", "/v1/appScreenshots", {
                "data": {
                    "type": "appScreenshots",
                    "attributes": {"fileName": name, "fileSize": len(data)},
                    "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
                }
            })
            upload_bytes(reserved["data"]["attributes"]["uploadOperations"], data)
            call(auth, "PATCH", f"/v1/appScreenshots/{reserved['data']['id']}", {
                "data": {
                    "type": "appScreenshots",
                    "id": reserved["data"]["id"],
                    "attributes": {"uploaded": True},
                }
            })
            print("uploaded", display, name)


def find_valid_build(auth, number):
    for _ in range(6):
        params = urllib.parse.urlencode({
            "filter[app]": APP,
            "filter[version]": number,
            "filter[processingState]": "VALID",
            "limit": 5,
        })
        found = call(auth, "GET", "/v1/builds?" + params)
        for item in found.get("data", []):
            if str(item.get("attributes", {}).get("version")) == str(number):
                return item
        print("build", number, "not VALID yet")
        time.sleep(20)
    fail(f"build {number} is not VALID")


def account_phone(auth):
    """Use a review phone already saved on this developer account. Do not invent one."""
    apps = soft(auth, "GET", "/v1/apps?limit=50") or {}
    for app in apps.get("data", []):
        versions = soft(auth, "GET", f"/v1/apps/{app['id']}/appStoreVersions?limit=8") or {}
        for version in versions.get("data", []):
            detail = soft(auth, "GET", f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail") or {}
            phone = ((detail.get("data") or {}).get("attributes") or {}).get("contactPhone")
            if phone:
                print("found a review phone already saved on this developer account")
                return phone
    return ""


def review_notes(auth, version_id):
    found = soft(auth, "GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    attributes = {
        "contactFirstName": "Trader",
        "contactLastName": "Goods",
        "contactEmail": "support@tradergoods.us",
        "notes": NOTES,
    }
    existing_phone = (((found or {}).get("data") or {}).get("attributes") or {}).get("contactPhone")
    phone = existing_phone or account_phone(auth)
    if phone:
        attributes["contactPhone"] = phone
    if found and found.get("data"):
        patch_attributes(auth, f"/v1/appStoreReviewDetails/{found['data']['id']}", "appStoreReviewDetails", found["data"]["id"], attributes)
        return
    created = soft(auth, "POST", "/v1/appStoreReviewDetails", {
        "data": {
            "type": "appStoreReviewDetails",
            "attributes": attributes,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}},
        }
    })
    if created is None:
        fail("Apple requires a review contact phone number, and this developer account has none saved. Add a phone in App Store Connect for the TrueFoods review contact, then the submission can be sent.")


def main():
    number = os.environ["BUILD_NUMBER"]
    folder = pathlib.Path(os.environ.get("SHOTS", "artifacts/screenshots"))
    for names in SHOTS.values():
        for name in names:
            if not (folder / name).is_file():
                fail(f"missing screenshot {name}")
    page_live(SUPPORT)
    page_live(PRIVACY)
    auth = signing.token()
    version = find_version(auth)
    version_id = version["id"]
    state = version.get("attributes", {}).get("appStoreState")
    print("version 1.0", version_id, state)
    if state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "READY_FOR_SALE", "PROCESSING_FOR_APP_STORE"):
        print(f"SUBMITTED build {number} state {state}")
        return
    patch_attributes(auth, f"/v1/appStoreVersions/{version_id}", "appStoreVersions", version_id, {
        "copyright": "2026 Trader Goods",
        "releaseType": "MANUAL",
        "versionString": "1.0",
    })
    info = app_info(auth)
    set_categories(auth, info["id"])
    locales = call(auth, "GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations")
    locale = next((item for item in locales.get("data", []) if str(item.get("attributes", {}).get("locale", "")).startswith("en")), None)
    if locale is None and locales.get("data"):
        locale = locales["data"][0]
    if locale is None:
        fail("the app has no English name localization")
    patch_attributes(auth, f"/v1/appInfoLocalizations/{locale['id']}", "appInfoLocalizations", locale["id"], {
        "subtitle": SUBTITLE,
        "privacyPolicyUrl": PRIVACY,
    })
    copy = localization(auth, version_id)
    if len(DESCRIPTION) > 4000 or len(KEYWORDS) > 100 or len(SUBTITLE) > 30:
        fail("metadata is over Apple's length limit")
    patch_attributes(auth, f"/v1/appStoreVersionLocalizations/{copy['id']}", "appStoreVersionLocalizations", copy["id"], {
        "description": DESCRIPTION,
        "keywords": KEYWORDS,
        "supportUrl": SUPPORT,
    })
    set_age_rating(auth, info["id"])
    set_price(auth)
    declare_privacy(auth)
    upload_screenshots(auth, copy["id"], folder)
    review_notes(auth, version_id)
    build = find_valid_build(auth, number)
    if build.get("attributes", {}).get("usesNonExemptEncryption") is None:
        soft(auth, "PATCH", f"/v1/builds/{build['id']}", {
            "data": {"type": "builds", "id": build["id"], "attributes": {"usesNonExemptEncryption": False}}
        })
    attached = call(auth, "PATCH", f"/v1/appStoreVersions/{version_id}", {
        "data": {
            "type": "appStoreVersions",
            "id": version_id,
            "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}},
        }
    })
    print("attached build", number, attached.get("data", {}).get("attributes", {}).get("appStoreState"))
    submission = call(auth, "POST", "/v1/appStoreVersionSubmissions", {
        "data": {
            "type": "appStoreVersionSubmissions",
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}},
        }
    })
    final = call(auth, "GET", f"/v1/appStoreVersions/{version_id}")
    status = final.get("data", {}).get("attributes", {}).get("appStoreState")
    print("submission", submission.get("data", {}).get("id"), status)
    if status not in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "READY_FOR_SALE", "PROCESSING_FOR_APP_STORE"):
        fail(f"submit finished but version state is {status}")
    print(f"SUBMITTED build {number} state {status}")


if __name__ == "__main__":
    try:
        main()
    except Blocker:
        raise
    except urllib.error.URLError as error:
        fail(str(error))
