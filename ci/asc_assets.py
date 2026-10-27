#!/usr/bin/env python3
"""Lädt Kopfbild und Suchergebnis-Bild je Sprache in die App Asset Library und setzt sie auf die Produktseite
der Version in Vorbereitung (ersetzt vorhandene Platzierungen gleicher Art).
Ordner: <dir>/header/<sprache>.jpg und <dir>/search/<sprache>.jpg (Branch „store-assets“).
Aufruf: asc_assets.py <bundle-id> <dir>"""
import json, os, sys, time, urllib.request
sys.path.insert(0, os.path.dirname(__file__))
from asc import api

KINDS = {"header": "PRODUCT_PAGE_HEADER_ASSET", "search": "APP_STORE_SEARCH_RESULTS_ASSET"}

def safe(method, path, body=None):
    try: return api(method, path, body)
    except SystemExit: return None

def upload(library_id, path):
    data = open(path, "rb").read()
    r = api("POST", "/v1/appAssetLibraryImages", {"data": {"type": "appAssetLibraryImages",
            "attributes": {"category": "CREATIVE_ASSETS", "fileName": os.path.basename(path), "fileSize": len(data)},
            "relationships": {"assetLibrary": {"data": {"type": "appAssetLibraries", "id": library_id}}}}})["data"]
    for op in r["attributes"]["uploadOperations"]:
        req = urllib.request.Request(op["url"], data=data[op["offset"]:op["offset"] + op["length"]], method=op["method"])
        for h in op.get("requestHeaders") or []: req.add_header(h["name"], h["value"])
        urllib.request.urlopen(req, timeout=180).read()
    api("PATCH", f"/v1/appAssetLibraryImages/{r['id']}", {"data": {"type": "appAssetLibraryImages", "id": r["id"],
        "attributes": {"uploaded": True}}})
    for _ in range(60):
        state = api("GET", f"/v1/appAssetLibraryImages/{r['id']}")["data"]["attributes"].get("state")
        if state not in ("AWAITING_UPLOAD", "UPLOAD_COMPLETE"): break
        time.sleep(5)
    return r["id"], state

def main(bundle, root):
    listing = json.load(open(os.path.join(os.path.dirname(__file__), "..", "docs", "store-listing.json"), encoding="utf-8"))
    app_id = api("GET", f"/v1/apps?filter[bundleId]={bundle}")["data"][0]["id"]
    library = api("GET", f"/v1/apps/{app_id}/assetLibrary")["data"]["id"]
    versions = api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
    version = next(v for v in versions if v["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION")
    locs = {l["attributes"]["locale"]: l["id"] for l in
            api("GET", f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations?limit=50")["data"]}
    failed = 0
    for lang, info in listing["languages"].items():
        for kind, placement in KINDS.items():
            path = next((os.path.join(root, kind, f"{lang}.{ext}") for ext in ("jpg", "png")
                         if os.path.exists(os.path.join(root, kind, f"{lang}.{ext}"))), None)
            if not path: print(f"{lang} {kind}: keine Datei"); continue
            try:
                image_id, state = upload(library, path)
            except (SystemExit, Exception) as e:
                print(f"{lang} {kind}: Hochladen fehlgeschlagen ({e})"); failed += 1; continue
            print(f"{lang} {kind}: hochgeladen ({state})")
            for locale in info["locales"]:
                if locale not in locs: print(f"  {locale}: Sprache fehlt"); failed += 1; continue
                for p in (safe("GET", f"/v1/appStoreVersionLocalizations/{locs[locale]}/placements") or {}).get("data", []):
                    if p["attributes"].get("placementType") == placement:
                        safe("DELETE", f"/v1/appAssetLibraryPlacements/{p['id']}")
                r = safe("POST", "/v1/appAssetLibraryPlacements", {"data": {"type": "appAssetLibraryPlacements",
                         "attributes": {"placementType": placement},
                         "relationships": {
                             "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": locs[locale]}},
                             "image": {"data": {"type": "appAssetLibraryImages", "id": image_id}}}}})
                print(f"  {locale}: {'gesetzt' if r else 'FEHLER beim Setzen'}")
                if not r: failed += 1
    if failed:
        ref = safe("GET", "/v1/appAssetLibraryRefData")
        if ref: print("Referenzdaten:", json.dumps(ref, ensure_ascii=False)[:1500])
    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
