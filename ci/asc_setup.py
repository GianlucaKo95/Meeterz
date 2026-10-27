#!/usr/bin/env python3
"""Restliche Pflichtangaben für die Einreichung per API: Inhaltsrechte, Altersfreigabe, Copyright, Preis (kostenlos).
Aufruf: asc_setup.py <bundle-id> show|apply
  show  – zeigt den aktuellen Stand (u. a. alle Felder der Altersfreigabe), ändert nichts
  apply – setzt die Werte aus ANSWERS unten"""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from asc import api

COPYRIGHT = "2026 Gianluca Köhni"
# Altersfreigabe: Meeterz hat Nachrichten zwischen Freunden und selbst erstellte Inhalte (Profilbild, Sprachschnipsel),
# sonst nichts davon. Alles, was hier nicht steht, wird auf „keine“ bzw. „nein“ gesetzt.
YES = {"messagingAndChat", "userGeneratedContent"}
# Felder, die keine Ja/Nein- oder Häufigkeitsfrage sind – nie anfassen
SKIP = {"kidsAgeBand", "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride", "developerAgeRatingInfoUrl"}

def safe(method, path, body=None):
    try: return api(method, path, body)
    except SystemExit: return None

def main(bundle, mode):
    app = api("GET", f"/v1/apps?filter[bundleId]={bundle}")["data"][0]
    app_id = app["id"]
    print(f"App {app_id}: Inhaltsrechte = {app['attributes'].get('contentRightsDeclaration')}")

    infos = api("GET", f"/v1/apps/{app_id}/appInfos")["data"]
    info = next((i for i in infos if i["attributes"].get("appStoreState") not in ("READY_FOR_SALE", "REPLACED_WITH_NEW_INFO")), infos[0])
    decl = safe("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration")
    decl = decl and decl.get("data")
    if decl:
        print("Altersfreigabe, aktuelle Felder:")
        for k, v in decl["attributes"].items(): print(f"  {k} = {v!r}")

    versions = api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
    version = next((v for v in versions if v["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION"), None)
    if version: print(f"Version {version['attributes']['versionString']}: Copyright = {version['attributes'].get('copyright')!r}")

    sched = safe("GET", f"/v1/apps/{app_id}/appPriceSchedule?include=baseTerritory,manualPrices")
    print("Preisplan:", "vorhanden" if sched and sched.get("data") else "keiner",
          json.dumps([x["attributes"] for x in (sched or {}).get("included", []) if x["type"] == "appPrices"])[:300])

    if mode != "apply": return 0
    print("\n== Änderungen ==")

    r = safe("PATCH", f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id,
             "attributes": {"contentRightsDeclaration": "USES_THIRD_PARTY_CONTENT"}}})
    print("Inhaltsrechte:", "ok (nutzt Inhalte Dritter mit Rechten: Karten, Ladesäulen-Daten)" if r is not None else "FEHLER")

    if decl:
        attrs = {}
        for k, v in decl["attributes"].items():
            if k in SKIP: continue
            if isinstance(v, bool) or v is None and (k.startswith("is") or k in YES or k.endswith(("Content", "Access", "Chat", "Controls", "Assurance", "Advertising", "Boxes", "Contests"))):
                attrs[k] = k in YES
            elif isinstance(v, str) or v is None:
                attrs[k] = "NONE"
        r = safe("PATCH", f"/v1/ageRatingDeclarations/{decl['id']}", {"data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": attrs}})
        print("Altersfreigabe:", "ok" if r is not None else "FEHLER", json.dumps(attrs, ensure_ascii=False))

    if version:
        r = safe("PATCH", f"/v1/appStoreVersions/{version['id']}", {"data": {"type": "appStoreVersions", "id": version["id"],
                 "attributes": {"copyright": COPYRIGHT}}})
        print("Copyright:", "ok" if r is not None else "FEHLER")

    # Preis: kostenlos, Basisland Deutschland
    points = safe("GET", f"/v1/apps/{app_id}/appPricePoints?filter[territory]=DEU&limit=200") or {}
    free = next((p for p in points.get("data", []) if float(p["attributes"].get("customerPrice") or 1) == 0), None)
    if not free:
        print("Preis: kein kostenloser Preispunkt gefunden")
    else:
        r = safe("POST", "/v1/appPriceSchedules", {
            "data": {"type": "appPriceSchedules", "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "baseTerritory": {"data": {"type": "territories", "id": "DEU"}},
                "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
            "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                          "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})
        print("Preis:", "ok (kostenlos)" if r is not None else "FEHLER")
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "show"))
