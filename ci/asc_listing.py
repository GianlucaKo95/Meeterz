#!/usr/bin/env python3
"""Befüllt die Produktseite in App Store Connect aus docs/store-listing.json – alle Sprachen auf einmal.
  App-Informationen (je Sprache): Name, Untertitel, Datenschutz-URL
  Version in Vorbereitung (je Sprache): Beschreibung, Keywords, Werbetext, Support- und Marketing-URL
Fehlende Sprachen werden angelegt, vorhandene überschrieben. Eingereicht wird nichts.
Aufruf: asc_listing.py <bundle-id> [--dry-run]"""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from asc import api

EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "WAITING_FOR_REVIEW", "INVALID_BINARY"}

def main(bundle, dry):
    data = json.load(open(os.path.join(os.path.dirname(__file__), "..", "docs", "store-listing.json"), encoding="utf-8"))
    apps = api("GET", f"/v1/apps?filter[bundleId]={bundle}")["data"]
    if not apps: print("App nicht gefunden"); return 1
    app = apps[0]; app_id = app["id"]
    print(f"App {app_id}, Primärsprache {app['attributes'].get('primaryLocale')}")

    wanted = {}   # locale -> Felder
    for lang in data["languages"].values():
        for loc in lang["locales"]:
            wanted[loc] = lang

    # --- App-Informationen (die bearbeitbare, also nicht die bereits veröffentlichte) ---
    infos = api("GET", f"/v1/apps/{app_id}/appInfos")["data"]
    info = next((i for i in infos if i["attributes"].get("appStoreState") not in ("READY_FOR_SALE", "REPLACED_WITH_NEW_INFO")), infos[0])
    print(f"App-Informationen {info['id']} ({info['attributes'].get('appStoreState') or info['attributes'].get('state')})")
    existing = {l["attributes"]["locale"]: l for l in api("GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=50")["data"]}
    for loc, f in wanted.items():
        # Namen sind je Sprache eindeutig im ganzen Store – ist einer vergeben, kommt der nächste Vorschlag
        for i, name in enumerate(f["names"]):
            attrs = {"name": name, "subtitle": f["subtitle"], "privacyPolicyUrl": f["privacyPolicyUrl"]}
            try:
                if loc in existing:
                    print(f"  {loc}: App-Informationen aktualisieren ({name})")
                    if not dry: api("PATCH", f"/v1/appInfoLocalizations/{existing[loc]['id']}",
                                    {"data": {"type": "appInfoLocalizations", "id": existing[loc]["id"], "attributes": attrs}})
                else:
                    print(f"  {loc}: Sprache anlegen (App-Informationen, {name})")
                    if not dry: api("POST", "/v1/appInfoLocalizations", {"data": {"type": "appInfoLocalizations",
                                    "attributes": {"locale": loc, **attrs},
                                    "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info["id"]}}}}})
                break
            except SystemExit:
                if i == len(f["names"]) - 1: raise
                print(f"    Name „{name}“ nicht möglich – nächster Vorschlag")

    # --- Version in Vorbereitung ---
    versions = api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
    version = next((v for v in versions if v["attributes"].get("appStoreState") in EDITABLE), None)
    if not version:
        print("Keine bearbeitbare Version gefunden – bitte in App Store Connect zuerst die Version 1.0 anlegen.")
        print("Vorhandene: " + ", ".join(f"{v['attributes']['versionString']} ({v['attributes'].get('appStoreState')})" for v in versions))
        return 1
    print(f"Version {version['attributes']['versionString']} ({version['attributes'].get('appStoreState')})")
    existing = {l["attributes"]["locale"]: l for l in api("GET", f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations?limit=50")["data"]}
    for loc, f in wanted.items():
        attrs = {"description": f["description"], "keywords": f["keywords"], "promotionalText": f["promotionalText"],
                 "supportUrl": data["supportUrl"], "marketingUrl": data["marketingUrl"]}
        if loc in existing:
            print(f"  {loc}: Texte der Version aktualisieren")
            if not dry: api("PATCH", f"/v1/appStoreVersionLocalizations/{existing[loc]['id']}",
                            {"data": {"type": "appStoreVersionLocalizations", "id": existing[loc]["id"], "attributes": attrs}})
        else:
            print(f"  {loc}: Sprache anlegen (Version)")
            if not dry: api("POST", "/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations",
                            "attributes": {"locale": loc, **attrs},
                            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
    print("Fertig." if not dry else "Probelauf – nichts geändert.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1], "--dry-run" in sys.argv))
