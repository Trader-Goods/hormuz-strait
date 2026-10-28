#!/usr/bin/env python3
"""Install an App Store certificate and provisioning profile for CI.

Uses KEY_PATH, KID, ISS, BUNDLE_ID, and TEAM_ID. Prints status only.
"""

import base64
import json
import os
import secrets
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

PROFILE_NAME = "Contractor CI"
API = "https://api.appstoreconnect.apple.com"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_len(buf, index):
    size = buf[index]
    if size < 0x80:
        return size, index + 1
    count = size & 0x7F
    value = int.from_bytes(buf[index + 1 : index + 1 + count], "big")
    return value, index + 1 + count


def jose_int(raw):
    raw = raw.lstrip(b"\x00")
    if len(raw) > 32:
        raise SystemExit("signature integer is too long")
    return raw.rjust(32, b"\x00")


def ecdsa_der_to_raw(der):
    if der[0] != 0x30:
        raise SystemExit("signature is not a DER sequence")
    _, index = der_len(der, 1)
    if der[index] != 0x02:
        raise SystemExit("signature is missing r")
    index += 1
    length, index = der_len(der, index)
    r = der[index : index + length]
    index += length
    if der[index] != 0x02:
        raise SystemExit("signature is missing s")
    index += 1
    length, index = der_len(der, index)
    s = der[index : index + length]
    return jose_int(r) + jose_int(s)


def token():
    header = b64url(json.dumps({"alg": "ES256", "kid": os.environ["KID"], "typ": "JWT"}, separators=(",", ":")).encode())
    now = int(time.time())
    payload = b64url(json.dumps({
        "iss": os.environ["ISS"],
        "iat": now,
        "exp": now + 600,
        "aud": "appstoreconnect-v1",
    }, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.check_output(["openssl", "dgst", "-sha256", "-sign", os.environ["KEY_PATH"]], input=signing_input)
    return f"{header}.{payload}.{b64url(ecdsa_der_to_raw(der))}"


def api(method, path, auth, body=None, quiet=False):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={"Authorization": "Bearer " + auth, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read().decode()
        print(f"API {method} {path.split('?')[0]} failed: {error.code}")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {}
        if not quiet:
            for item in payload.get("errors", []):
                print(item.get("status"), item.get("code"), item.get("title"), item.get("detail"))
        failure = SystemExit(1)
        failure.code = error.code
        raise failure


def set_env(key, value):
    with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as handle:
        handle.write(f"{key}<<EOF\n{value}\nEOF\n")


def bundle_id(auth, identifier):
    query = urllib.parse.urlencode({"filter[identifier]": identifier, "limit": 5})
    found = api("GET", "/v1/bundleIds?" + query, auth).get("data", [])
    for item in found:
        if item.get("attributes", {}).get("identifier") == identifier:
            print("bundle id found")
            return item["id"]
    created = api("POST", "/v1/bundleIds", auth, {
        "data": {
            "type": "bundleIds",
            "attributes": {"identifier": identifier, "name": "Contractor", "platform": "IOS"},
        }
    })
    print("bundle id created")
    return created["data"]["id"]


def quiet(cmd, env=None):
    result = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
    if result.returncode != 0:
        text = result.stderr.decode("utf-8", "replace")
        safe = [line for line in text.splitlines() if "PRIVATE" not in line and "-----" not in line]
        print("command failed:", " ".join(safe)[:300])
        raise SystemExit(1)


def export_p12(key_path, pem_path, p12_path, password, legacy):
    env = os.environ.copy()
    env["P12_PASS"] = password
    cmd = [
        "openssl", "pkcs12", "-export", "-inkey", key_path, "-in", pem_path,
        "-out", p12_path, "-passout", "env:P12_PASS", "-name", "Apple Distribution",
    ]
    if legacy:
        cmd.append("-legacy")
    quiet(cmd, env)


def list_distribution_certificates(auth):
    found = []
    for kind in ("IOS_DISTRIBUTION", "DISTRIBUTION"):
        query = urllib.parse.urlencode({"filter[certificateType]": kind, "limit": 20})
        found.extend(api("GET", "/v1/certificates?" + query, auth).get("data", []))
    return found


def app_store_profiles(auth):
    query = urllib.parse.urlencode({"filter[profileType]": "IOS_APP_STORE", "limit": 200})
    return api("GET", "/v1/profiles?" + query, auth).get("data", [])


def profile_certificate_ids(auth, profile_id):
    payload = api("GET", "/v1/profiles/" + profile_id + "/relationships/certificates", auth)
    return [item["id"] for item in payload.get("data", []) if item.get("id")]


def revoke_one_distribution_certificate(auth):
    """Replace only the certificate on the Spam Sweep CI profile.

    Distribution certificates are named for the account, not the app, so a name
    match cannot tell Spam Sweep apart from Live to Still. A certificate that is
    also attached to another App Store profile is left alone.
    """
    profiles = app_store_profiles(auth)
    own_ids = set()
    other_ids = set()
    for item in profiles:
        name = item.get("attributes", {}).get("name") or ""
        ids = profile_certificate_ids(auth, item["id"])
        if name == PROFILE_NAME:
            own_ids.update(ids)
        else:
            other_ids.update(ids)
    safe = [cert_id for cert_id in own_ids if cert_id not in other_ids]
    if not safe:
        raise SystemExit("certificate limit reached; other apps' certificates were left in place")
    known = {item["id"] for item in list_distribution_certificates(auth)}
    revoked = False
    for cert_id in safe:
        if cert_id not in known:
            continue
        try:
            api("DELETE", "/v1/certificates/" + cert_id, auth)
        except SystemExit as error:
            if getattr(error, "code", None) != 404:
                raise
        print("revoked certificate attached to Contractor CI")
        revoked = True
    if not revoked:
        raise SystemExit("certificate limit reached; other apps' certificates were left in place")


SHARED_PROFILE_NAMES = ("Spam Sweep CI", "Live to Still CI")


def choose_shared_certificate(auth):
    """Use the distribution certificate already attached to the other apps.

    Does not create or revoke a certificate.
    """
    profiles = app_store_profiles(auth)
    used = []
    for item in profiles:
        name = (item.get("attributes") or {}).get("name") or ""
        if name not in SHARED_PROFILE_NAMES:
            continue
        ids = profile_certificate_ids(auth, item["id"])
        print(f"profile {name} has an existing distribution certificate")
        used.extend(ids)
    known = list_distribution_certificates(auth)
    by_id = {item["id"]: item for item in known}
    if not used:
        used = list(by_id)
        print("using an existing account distribution certificate")
    if not used:
        raise SystemExit("no existing distribution certificate to reuse")
    def expiry(certificate_id):
        attributes = (by_id.get(certificate_id) or {}).get("attributes") or {}
        return attributes.get("expirationDate") or ""
    chosen = sorted(set(used), key=expiry, reverse=True)[0]
    attributes = (by_id.get(chosen) or {}).get("attributes") or {}
    print("reusing existing distribution certificate")
    print(attributes.get("displayName") or attributes.get("name") or "distribution")
    print(attributes.get("expirationDate") or "")
    return chosen


def load_shared_p12(work):
    encoded = ""
    password = ""
    for name, pass_name in (
        ("DISTRIBUTION_P12", "DISTRIBUTION_P12_PASSWORD"),
        ("APPLE_DISTRIBUTION_P12", "APPLE_DISTRIBUTION_P12_PASSWORD"),
        ("IOS_DISTRIBUTION_P12", "IOS_DISTRIBUTION_P12_PASSWORD"),
    ):
        raw = (os.environ.get(name) or "").strip()
        if raw:
            encoded = raw
            password = os.environ.get(pass_name) or ""
            break
    if not encoded:
        raise SystemExit("missing DISTRIBUTION_P12 for the existing distribution certificate")
    try:
        blob = base64.b64decode(encoded)
    except Exception:
        raise SystemExit("DISTRIBUTION_P12 is not valid base64")
    path = os.path.join(work, "dist.p12")
    with open(path, "wb") as handle:
        handle.write(blob)
    os.chmod(path, 0o600)
    print("existing distribution p12 loaded")
    return path, password


def distribution_certificate(auth, work, replaced=False):
    key_path = os.path.join(work, "dist.key")
    csr_path = os.path.join(work, "dist.csr")
    cer_path = os.path.join(work, "dist.cer")
    pem_path = os.path.join(work, "dist.pem")
    p12_path = os.path.join(work, "dist.p12")
    quiet(["openssl", "genrsa", "-out", key_path, "2048"])
    quiet([
        "openssl", "req", "-new", "-key", key_path, "-out", csr_path,
        "-subj", "/CN=Contractor Distribution/O=Trader Goods",
    ])
    csr = open(csr_path, encoding="utf-8").read()
    created = None
    blocked = False
    for certificate_type in ("IOS_DISTRIBUTION", "DISTRIBUTION"):
        try:
            created = api("POST", "/v1/certificates", auth, {
                "data": {
                    "type": "certificates",
                    "attributes": {"certificateType": certificate_type, "csrContent": csr},
                }
            })
            print("distribution certificate created")
            break
        except SystemExit as error:
            print("certificate type was not accepted")
            if getattr(error, "code", None) == 409:
                blocked = True
            created = None
    if created is None and blocked and not replaced:
        revoke_one_distribution_certificate(auth)
        return distribution_certificate(auth, work, replaced=True)
    if created is None:
        raise SystemExit("could not create a distribution certificate")
    content = created["data"]["attributes"]["certificateContent"]
    open(cer_path, "wb").write(base64.b64decode(content))
    quiet(["openssl", "x509", "-inform", "DER", "-in", cer_path, "-out", pem_path])
    password = secrets.token_hex(16)
    export_p12(key_path, pem_path, p12_path, password, legacy=False)
    return created["data"]["id"], p12_path, password, key_path, pem_path


def app_store_profile(auth, bundle, certificate_id):
    query = urllib.parse.urlencode({"filter[name]": PROFILE_NAME, "filter[profileType]": "IOS_APP_STORE", "limit": 20})
    existing = api("GET", "/v1/profiles?" + query, auth).get("data", [])
    for item in existing:
        if item.get("attributes", {}).get("name") == PROFILE_NAME:
            api("DELETE", "/v1/profiles/" + item["id"], auth)
            print("replaced existing profile")
    created = api("POST", "/v1/profiles", auth, {
        "data": {
            "type": "profiles",
            "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
            },
        }
    })
    print("app store profile created")
    return base64.b64decode(created["data"]["attributes"]["profileContent"])


def install_profile(blob, work):
    path = os.path.join(work, "profile.mobileprovision")
    open(path, "wb").write(blob)
    plist = os.path.join(work, "profile.plist")
    with open(plist, "w", encoding="utf-8") as handle:
        subprocess.check_call(["security", "cms", "-D", "-i", path], stdout=handle)
    name = subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", "Print Name", plist], text=True).strip()
    uuid = subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", "Print UUID", plist], text=True).strip()
    destination = os.path.expanduser(f"~/Library/MobileDevice/Provisioning Profiles/{uuid}.mobileprovision")
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    open(destination, "wb").write(blob)
    print("profile installed")
    return name, uuid


def import_identity(p12_path, password, keychain):
    return subprocess.run(
        [
            "security", "import", p12_path, "-k", keychain, "-P", password, "-A",
            "-T", "/usr/bin/codesign", "-T", "/usr/bin/security",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def install_keychain(p12_path, password, work, key_path=None, pem_path=None):
    keychain = os.path.join(work, "build.keychain-db")
    quiet(["security", "create-keychain", "-p", password, keychain])
    quiet(["security", "set-keychain-settings", "-lut", "21600", keychain])
    quiet(["security", "unlock-keychain", "-p", password, keychain])
    imported = import_identity(p12_path, password, keychain)
    if imported.returncode != 0 and key_path and pem_path:
        print("retrying certificate import")
        export_p12(key_path, pem_path, p12_path, password, legacy=True)
        imported = import_identity(p12_path, password, keychain)
    if imported.returncode != 0:
        print("certificate import failed")
        raise SystemExit(1)
    quiet(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain])
    existing = subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True)
    paths = [line.strip().strip('"') for line in existing.splitlines() if line.strip()]
    quiet(["security", "list-keychains", "-d", "user", "-s", keychain, *paths])
    quiet(["security", "default-keychain", "-s", keychain])
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning", keychain], text=True)
    count = sum(1 for line in identities.splitlines() if "Apple Distribution" in line or "iPhone Distribution" in line)
    if count < 1:
        print("no distribution identity in keychain")
        raise SystemExit(1)
    print("distribution identity installed")
    return keychain


def find_app(auth, identifier):
    known = os.environ.get("ASC_APP_ID", "6828019050")
    if known:
        try:
            item = api("GET", "/v1/apps/" + known, auth).get("data") or {}
            bundle = (item.get("attributes") or {}).get("bundleId")
            if item.get("id") and bundle == identifier:
                print("app record found")
                print((item.get("attributes") or {}).get("name") or "")
                return item["id"]
        except SystemExit:
            print("known app id was not readable")
    query = urllib.parse.urlencode({"filter[bundleId]": identifier, "limit": 5})
    found = api("GET", "/v1/apps?" + query, auth).get("data", [])
    for item in found:
        if item.get("attributes", {}).get("bundleId") == identifier:
            print("app record found")
            print(item.get("attributes", {}).get("name") or "")
            return item["id"]
    return None


def ensure_app(auth, bundle_resource, identifier):
    query = urllib.parse.urlencode({"filter[bundleId]": identifier, "limit": 5})
    found = api("GET", "/v1/apps?" + query, auth).get("data", [])
    for item in found:
        if item.get("attributes", {}).get("bundleId") == identifier:
            print("app record found")
            return item["id"]
    attempts = [
        {
            "data": {
                "type": "apps",
                "attributes": {
                    "name": "Contractor",
                    "primaryLocale": "en-US",
                    "sku": "contractor",
                    "bundleId": identifier,
                },
            }
        },
        {
            "data": {
                "type": "apps",
                "attributes": {
                    "name": "Contractor",
                    "primaryLocale": "en-US",
                    "sku": "contractor",
                },
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource}},
                },
            }
        },
    ]
    last = None
    for payload in attempts:
        try:
            created = api("POST", "/v1/apps", auth, payload)
            print("app record created")
            return created["data"]["id"]
        except SystemExit as error:
            last = error
            print("app create attempt was not accepted")
    print("app record was not created")
    print("bundle id is registered")
    print("create it in App Store Connect if the API cannot: New App, iOS, Contractor, com.tradergoods.contractor, SKU contractor, English (U.S.)")
    print("status", getattr(last, "code", ""))
    print("continuing so the archive can be signed; TestFlight upload needs that app record")
    return None


def main():
    for name in ("KEY_PATH", "KID", "ISS", "BUNDLE_ID", "GITHUB_ENV"):
        if not os.environ.get(name):
            raise SystemExit(f"missing {name}")
    work = os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "signing")
    os.makedirs(work, exist_ok=True)
    os.chmod(work, 0o700)
    identifier = os.environ["BUNDLE_ID"]
    auth = token()
    if not find_app(auth, identifier):
        raise SystemExit("app record was not found for " + identifier)
    bundle = bundle_id(auth, identifier)
    certificate_id = choose_shared_certificate(auth)
    try:
        p12_path, password = load_shared_p12(work)
        key_path = None
        pem_path = None
    except SystemExit:
        print("no stored p12; signing the same way as the other apps")
        certificate_id, p12_path, password, key_path, pem_path = distribution_certificate(auth, work)
    profile = app_store_profile(auth, bundle, certificate_id)
    name, uuid = install_profile(profile, work)
    keychain = install_keychain(p12_path, password, work, key_path, pem_path)
    set_env("PROFILE_NAME", name)
    set_env("PROFILE_UUID", uuid)
    set_env("KEYCHAIN_PATH", keychain)
    print("signing material ready")


if __name__ == "__main__":
    main()
