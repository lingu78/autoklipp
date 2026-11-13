#!/usr/bin/env python3
"""Fills in the App Store product page from AppStore/ with the App Store Connect API.

Runs in GitHub Actions (.github/workflows/appstore.yml) with the same API key as the TestFlight
workflow. Standard library only; the token is signed with the openssl command.

What it sets, for the app version that is being prepared (1.0):
  - per language (AppStore/en-US, AppStore/sv): description, keywords, promotional text, and
    support, marketing and privacy policy URLs where the files exist; name and subtitle;
  - the category (Photo & Video);
  - the notes for App Review (AppStore/review_notes.txt);
  - the iPhone 6.9" screenshots (AppStore/images/iphone-69-*.jpg), replacing those there;
  - the newest processed build of this version, if there is one.

Not possible or not wise through the API, left to App Store Connect: the header and search
results images, App Privacy ("Data Not Collected"), the age rating questionnaire, contact
details for App Review, price and availability, and the copyright line.

    python3 scripts/app_store_connect.py --key AuthKey.p8 [--dry-run]
"""
import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://api.appstoreconnect.apple.com"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AppStore")
LOCALES = {"en-US": "en-US", "sv": "sv"}
SCREENSHOT_TYPE = "APP_IPHONE_67"  # the 6.9" set (1320 x 2868) in the API
CATEGORY = "PHOTO_AND_VIDEO"


class ApiError(Exception):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body[:600]}")
        self.status = status


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    """An ECDSA signature from DER (as openssl writes it) to the 64 bytes JWT expects."""
    assert der[0] == 0x30
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    numbers = []
    for _ in range(2):
        assert der[index] == 0x02
        length = der[index + 1]
        numbers.append(int.from_bytes(der[index + 2:index + 2 + length], "big"))
        index += 2 + length
    return numbers[0].to_bytes(32, "big") + numbers[1].to_bytes(32, "big")


class Client:
    def __init__(self, key_path, key_id, issuer_id, dry_run):
        self.key_path, self.key_id, self.issuer_id, self.dry_run = key_path, key_id, issuer_id, dry_run
        self._token, self._made = None, 0

    def token(self):
        if self._token and time.time() - self._made < 900:
            return self._token
        now = int(time.time())
        header = b64url(json.dumps({"alg": "ES256", "kid": self.key_id, "typ": "JWT"}).encode())
        payload = b64url(json.dumps({"iss": self.issuer_id, "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"}).encode())
        signing_input = f"{header}.{payload}"
        der = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.key_path], input=signing_input.encode(), capture_output=True, check=True
        ).stdout
        self._token, self._made = f"{signing_input}.{b64url(der_to_raw(der))}", time.time()
        return self._token

    def request(self, method, path, body=None, params=None):
        if method != "GET" and self.dry_run:
            print(f"  (dry run) {method} {path}")
            return {}
        url = path if path.startswith("http") else BASE + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token()}", "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                text = response.read()
                return json.loads(text) if text else {}
        except urllib.error.HTTPError as error:
            raise ApiError(error.code, error.read().decode(errors="replace")) from None

    def get(self, path, **params):
        return self.request("GET", path, params=params or None)

    def upload_part(self, operation, data):
        if self.dry_run:
            return
        part = data[operation["offset"]:operation["offset"] + operation["length"]]
        headers = {header["name"]: header["value"] for header in operation.get("requestHeaders", [])}
        request = urllib.request.Request(operation["url"], data=part, method=operation["method"], headers=headers)
        with urllib.request.urlopen(request, timeout=120) as response:
            response.read()


def read(locale_folder, name):
    path = os.path.join(ROOT, locale_folder, name)
    if not os.path.exists(path):
        return None
    text = open(path, encoding="utf-8").read().strip()
    return text or None


def delivery_state(asset):
    return (asset["attributes"].get("assetDeliveryState") or {}).get("state")


def report(api, app_id, version_id):
    """Prints what the version has now, per language: screenshots and app previews, and whether
    Apple has finished processing each (COMPLETE) or refused it (FAILED, with the reason)."""
    app = api.get(f"/v1/apps/{app_id}")["data"]
    print()
    print(f"App Store Connect now (primary language {app['attributes'].get('primaryLocale')}):")
    for localization in api.get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations", limit="50")["data"]:
        print(f"  {localization['attributes'].get('locale')}:")
        kinds = [
            ("appScreenshotSets", "screenshotDisplayType", "appScreenshots", "screenshots"),
            ("appPreviewSets", "previewType", "appPreviews", "app previews"),
        ]
        for sets_path, type_key, items_path, label in kinds:
            sets = api.get(f"/v1/appStoreVersionLocalizations/{localization['id']}/{sets_path}", limit="50")["data"]
            if not sets:
                print(f"    {label}: none")
            for item_set in sets:
                items = api.get(f"/v1/{sets_path}/{item_set['id']}/{items_path}", limit="50")["data"]
                print(f"    {label} {item_set['attributes'].get(type_key)}: {len(items)}")
                for item in items:
                    attributes = item["attributes"]
                    state = attributes.get("assetDeliveryState") or {}
                    size = attributes.get("imageAsset") or {}
                    dimensions = f" {size.get('width')}x{size.get('height')}" if size else ""
                    problems = [error.get("description") or error.get("code") for error in state.get("errors") or []]
                    print(f"      {attributes.get('fileName')}{dimensions}: {state.get('state')}"
                          + (f" – {'; '.join(map(str, problems))}" if problems else ""))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--key", required=True)
    parser.add_argument("--key-id", default=os.environ.get("KEY_ID"))
    parser.add_argument("--issuer-id", default=os.environ.get("ISSUER_ID"))
    parser.add_argument("--bundle-id", default=os.environ.get("BUNDLE_ID", "se.autoklipp.app"))
    parser.add_argument("--version", default="1.0")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--report", action="store_true", help="only report what App Store Connect has")
    args = parser.parse_args()
    api = Client(args.key, args.key_id, args.issuer_id, args.dry_run)
    done, failed = [], []

    def step(name, action):
        try:
            action()
            done.append(name)
            print(f"✓ {name}")
        except Exception as error:  # noqa: BLE001 – one field failing must not stop the rest
            failed.append(f"{name}: {error}")
            print(f"✗ {name}: {error}")

    apps = api.get("/v1/apps", **{"filter[bundleId]": args.bundle_id})["data"]
    if not apps:
        sys.exit(f"No app with bundle id {args.bundle_id} in App Store Connect.")
    app_id = apps[0]["id"]
    print(f"App {apps[0]['attributes'].get('name')} ({app_id})")

    versions = api.get(f"/v1/apps/{app_id}/appStoreVersions", **{"filter[platform]": "IOS", "limit": "20"})["data"]
    version = next((v for v in versions if v["attributes"].get("versionString") == args.version), None)
    if version is None:
        sys.exit(f"No version {args.version} in App Store Connect; found {[v['attributes'].get('versionString') for v in versions]}.")
    version_id = version["id"]
    state = version["attributes"].get("appVersionState") or version["attributes"].get("appStoreState")
    print(f"Version {args.version} ({version_id}), state {state}")
    if args.report:
        report(api, app_id, version_id)
        return

    # Version texts, per language.
    localizations = {item["attributes"]["locale"]: item for item in api.get(
        f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations", limit="50")["data"]}
    for locale, folder in LOCALES.items():
        attributes = {key: value for key, value in {
            "description": read(folder, "description.txt"),
            "keywords": read(folder, "keywords.txt"),
            "promotionalText": read(folder, "promotional_text.txt"),
            "supportUrl": read(folder, "support_url.txt"),
            "marketingUrl": read(folder, "marketing_url.txt"),
        }.items() if value}

        def update_version_texts(locale=locale, attributes=attributes):
            if locale in localizations:
                item = localizations[locale]
                api.request("PATCH", f"/v1/appStoreVersionLocalizations/{item['id']}", {
                    "data": {"type": "appStoreVersionLocalizations", "id": item["id"], "attributes": attributes}})
            else:
                created = api.request("POST", "/v1/appStoreVersionLocalizations", {"data": {
                    "type": "appStoreVersionLocalizations", "attributes": {**attributes, "locale": locale},
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
                if created:
                    localizations[locale] = created["data"]
        step(f"texts ({locale}): {', '.join(attributes)}", update_version_texts)

    # Name, subtitle and privacy policy, per language, and the category.
    infos = api.get(f"/v1/apps/{app_id}/appInfos")["data"]
    info = next((i for i in infos if (i["attributes"].get("state") or i["attributes"].get("appStoreState"))
                 not in ("READY_FOR_DISTRIBUTION", "READY_FOR_SALE")), infos[0])
    info_id = info["id"]
    step("category: Photo & Video", lambda: api.request("PATCH", f"/v1/appInfos/{info_id}", {"data": {
        "type": "appInfos", "id": info_id,
        "relationships": {"primaryCategory": {"data": {"type": "appCategories", "id": CATEGORY}}}}}))
    info_localizations = {item["attributes"]["locale"]: item for item in api.get(
        f"/v1/appInfos/{info_id}/appInfoLocalizations", limit="50")["data"]}
    for locale, folder in LOCALES.items():
        attributes = {key: value for key, value in {
            "name": read(folder, "name.txt"),
            "subtitle": read(folder, "subtitle.txt"),
            "privacyPolicyUrl": read(folder, "privacy_policy_url.txt"),
        }.items() if value}
        existing = info_localizations.get(locale)
        if existing and existing["attributes"].get("name") == attributes.get("name"):
            attributes.pop("name")  # unchanged; a name taken by another app would fail the rest

        def update_app_info(locale=locale, attributes=attributes, existing=existing):
            if existing:
                api.request("PATCH", f"/v1/appInfoLocalizations/{existing['id']}", {
                    "data": {"type": "appInfoLocalizations", "id": existing["id"], "attributes": attributes}})
            else:
                api.request("POST", "/v1/appInfoLocalizations", {"data": {
                    "type": "appInfoLocalizations", "attributes": {**attributes, "locale": locale},
                    "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info_id}}}}})
        step(f"app info ({locale}): {', '.join(attributes)}", update_app_info)

    # Notes for App Review.
    notes = read("", "review_notes.txt")
    if notes:
        def update_review_notes():
            try:
                detail = api.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail").get("data")
            except ApiError as error:
                if error.status != 404:
                    raise
                detail = None
            # Apple keeps the App Review details only together with the contact's name, phone and
            # e-mail, which are the developer's own and are not kept in the repository.
            missing_contact = RuntimeError(
                "fill in the contact details under App Review Information in App Store Connect "
                "first, then run this again (or paste review_notes.txt there)")
            if not detail:
                raise missing_contact
            try:
                api.request("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {
                    "type": "appStoreReviewDetails", "id": detail["id"],
                    "attributes": {"notes": notes, "demoAccountRequired": False}}})
            except ApiError as error:
                if error.status == 409 and "contact" in str(error):
                    raise missing_contact from error
                raise
        step("App Review notes", update_review_notes)

    # Screenshots for the 6.9" iPhone, on the primary language.
    images_folder = os.path.join(ROOT, "images")
    shots = sorted(name for name in os.listdir(images_folder) if name.startswith("iphone-69-")) if os.path.isdir(images_folder) else []
    if shots and "en-US" in localizations:
        def upload_screenshots():
            localization_id = localizations["en-US"]["id"]
            sets = api.get(f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets", limit="50")["data"]
            shot_set = next((s for s in sets if s["attributes"].get("screenshotDisplayType") == SCREENSHOT_TYPE), None)
            if shot_set is None:
                shot_set = api.request("POST", "/v1/appScreenshotSets", {"data": {
                    "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": SCREENSHOT_TYPE},
                    "relationships": {"appStoreVersionLocalization": {"data": {
                        "type": "appStoreVersionLocalizations", "id": localization_id}}}}}).get("data")
                if shot_set is None:  # dry run
                    return
            else:
                existing = api.get(f"/v1/appScreenshotSets/{shot_set['id']}/appScreenshots", limit="50")["data"]
                wanted = [(name, hashlib.md5(open(os.path.join(images_folder, name), "rb").read()).hexdigest()) for name in shots]
                there = [(old["attributes"].get("fileName"), old["attributes"].get("sourceFileChecksum")) for old in existing]
                processed = all(delivery_state(old) == "COMPLETE" for old in existing)
                if there == wanted and processed:
                    print("  unchanged")
                    return
                for old in existing:
                    print(f"  replacing {old['attributes'].get('fileName')} ({delivery_state(old)})")
                    api.request("DELETE", f"/v1/appScreenshots/{old['id']}")
            for name in shots:
                data = open(os.path.join(images_folder, name), "rb").read()
                reserved = api.request("POST", "/v1/appScreenshots", {"data": {
                    "type": "appScreenshots", "attributes": {"fileName": name, "fileSize": len(data)},
                    "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": shot_set["id"]}}}}})
                if not reserved:
                    continue
                shot = reserved["data"]
                for operation in shot["attributes"].get("uploadOperations") or []:
                    api.upload_part(operation, data)
                api.request("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {
                    "type": "appScreenshots", "id": shot["id"],
                    "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
                print(f"  uploaded {name} ({len(data) // 1024} KB)")
        step(f"screenshots: {len(shots)} for the 6.9\" iPhone", upload_screenshots)
    else:
        print("– no screenshots in AppStore/images yet")

    # The newest processed build of this version.
    def attach_build():
        builds = api.get("/v1/builds", **{
            "filter[app]": app_id, "filter[preReleaseVersion.version]": args.version,
            "filter[processingState]": "VALID", "sort": "-uploadedDate", "limit": "1"})["data"]
        if not builds:
            raise RuntimeError(f"no processed build of {args.version} yet; run TestFlight and try again")
        build = builds[0]
        api.request("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build", {
            "data": {"type": "builds", "id": build["id"]}})
        print(f"  build {build['attributes'].get('version')}")
    step("build", attach_build)

    if not args.dry_run:
        try:
            report(api, app_id, version_id)
        except ApiError as error:
            print(f"(no report: {error})")
    print()
    print(f"Done: {len(done)}, failed: {len(failed)}")
    for item in failed:
        print(f"  ✗ {item}")
    print("Still in App Store Connect by hand: header and search results images, App Privacy,")
    print("age rating, App Review contact details, price and availability, copyright.")
    if not args.dry_run and len(failed) > len(done):
        sys.exit(1)


if __name__ == "__main__":
    main()
