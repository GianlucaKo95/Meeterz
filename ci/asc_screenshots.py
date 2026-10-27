#!/usr/bin/env python3
"""Lädt die gerahmten App-Store-Screenshots je Sprache und Displaygröße in die Version in Vorbereitung.
Ordner: <dir>/<pro|promax>/<sprache>/<n>-<name>.jpg (Branch „store-screens“). Vorhandene Bilder im Satz werden ersetzt.
Aufruf: asc_screenshots.py <bundle-id> <dir>"""
import hashlib, json, os, sys, urllib.request
sys.path.insert(0, os.path.dirname(__file__))
from asc import api

# Displaygrößen in App Store Connect – mehrere Namen probieren (Apple benennt sie je nach API-Stand anders)
DISPLAY = {"pro": ["APP_IPHONE_63", "APP_IPHONE_61"], "promax": ["APP_IPHONE_69", "APP_IPHONE_67"]}

def safe(method, path, body=None):
    try: return api(method, path, body)
    except SystemExit: return None

def upload(set_id, path):
    data = open(path, "rb").read()
    r = api("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
            "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
    for op in r["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for h in op.get("requestHeaders") or []: req.add_header(h["name"], h["value"])
        urllib.request.urlopen(req, timeout=120).read()
    api("PATCH", f"/v1/appScreenshots/{r['id']}", {"data": {"type": "appScreenshots", "id": r["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})

def main(bundle, root):
    listing = json.load(open(os.path.join(os.path.dirname(__file__), "..", "docs", "store-listing.json"), encoding="utf-8"))
    app_id = api("GET", f"/v1/apps?filter[bundleId]={bundle}")["data"][0]["id"]
    versions = api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
    version = next(v for v in versions if v["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION")
    locs = {l["attributes"]["locale"]: l["id"] for l in
            api("GET", f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations?limit=50")["data"]}
    failed = 0
    for lang, info in listing["languages"].items():
        for locale in info["locales"]:
            if locale not in locs: print(f"{locale}: Sprache fehlt in der Version"); failed += 1; continue
            sets = {s["attributes"]["screenshotDisplayType"]: s["id"] for s in
                    api("GET", f"/v1/appStoreVersionLocalizations/{locs[locale]}/appScreenshotSets?limit=50")["data"]}
            for size, types in DISPLAY.items():
                folder = os.path.join(root, size, lang)
                if not os.path.isdir(folder): continue
                files = sorted(f for f in os.listdir(folder) if f.lower().endswith((".png", ".jpg")))
                set_id = next((sets[t] for t in types if t in sets), None)
                used = next((t for t in types if t in sets), None)
                if not set_id:
                    for t in types:
                        r = safe("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
                                 "attributes": {"screenshotDisplayType": t},
                                 "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": locs[locale]}}}}})
                        if r: set_id, used = r["data"]["id"], t; break
                if not set_id: print(f"{locale} {size}: kein Screenshot-Satz möglich"); failed += 1; continue
                for old in api("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=50")["data"]:
                    safe("DELETE", f"/v1/appScreenshots/{old['id']}")
                ok = 0
                for f in files:
                    try: upload(set_id, os.path.join(folder, f)); ok += 1
                    except (SystemExit, Exception) as e: print(f"  {locale} {size} {f}: {e}"); failed += 1
                print(f"{locale} {size} ({used}): {ok}/{len(files)} hochgeladen")
    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
