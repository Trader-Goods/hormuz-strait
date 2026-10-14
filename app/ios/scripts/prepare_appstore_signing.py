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

PROFILE_NAME = "Hormuz Strait CI"
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


def api(method, path, auth, body=None):
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
        for item in payload.get("errors", []):
            print(item.get("status"), item.get("code"), item.get("title"), item.get("detail"))
        raise SystemExit(1)


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
            "attributes": {"identifier": identifier, "name": "Hormuz Strait", "platform": "IOS"},
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


def distribution_certificate(auth, work):
    key_path = os.path.join(work, "dist.key")
    csr_path = os.path.join(work, "dist.csr")
    cer_path = os.path.join(work, "dist.cer")
    pem_path = os.path.join(work, "dist.pem")
    p12_path = os.path.join(work, "dist.p12")
    quiet(["openssl", "genrsa", "-out", key_path, "2048"])
    quiet([
        "openssl", "req", "-new", "-key", key_path, "-out", csr_path,
        "-subj", "/CN=Hormuz Strait Distribution/O=Trader Goods",
    ])
    csr = open(csr_path, encoding="utf-8").read()
    created = None
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
        except SystemExit:
            print("certificate type was not accepted")
            created = None
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


def install_keychain(p12_path, password, work, key_path, pem_path):
    keychain = os.path.join(work, "build.keychain-db")
    quiet(["security", "create-keychain", "-p", password, keychain])
    quiet(["security", "set-keychain-settings", "-lut", "21600", keychain])
    quiet(["security", "unlock-keychain", "-p", password, keychain])
    imported = import_identity(p12_path, password, keychain)
    if imported.returncode != 0:
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


def main():
    for name in ("KEY_PATH", "KID", "ISS", "BUNDLE_ID", "GITHUB_ENV"):
        if not os.environ.get(name):
            raise SystemExit(f"missing {name}")
    work = os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "signing")
    os.makedirs(work, exist_ok=True)
    os.chmod(work, 0o700)
    auth = token()
    bundle = bundle_id(auth, os.environ["BUNDLE_ID"])
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
