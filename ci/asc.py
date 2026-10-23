#!/usr/bin/env python3
"""Kleiner App-Store-Connect-API-Helfer (nur Standardbibliothek + openssl).
  asc.py create  <dir> <bundle-id> <profil-name>   erzeugt Zertifikat + App-Store-Profil
  asc.py cleanup <dir>                              löscht beides wieder
Benötigt: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (.p8)"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error

KEY_ID, ISSUER, KEY_PATH = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_PATH"]
BASE = "https://api.appstoreconnect.apple.com"

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def der_to_raw(der):
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    def take(i):
        assert der[i] == 0x02
        n = der[i + 1]; v = der[i + 2:i + 2 + n]
        return v.lstrip(b"\x00").rjust(32, b"\x00"), i + 2 + n
    r, i = take(i); s, _ = take(i)
    return r + s

def token():
    now = int(time.time())
    head = b64u(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    body = b64u(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{head}.{body}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY_PATH], input=signing_input,
                         capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64u(der_to_raw(der))}"

def api(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"API {method} {path} -> {e.code}: {e.read().decode()[:600]}", file=sys.stderr)
        raise SystemExit(40)

def create(workdir, bundle_identifier, profile_name):
    os.makedirs(workdir, exist_ok=True)
    key, csr = f"{workdir}/key.pem", f"{workdir}/req.csr"
    subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr,
                    "-subj", "/CN=Meeterz CI/O=Meeterz/C=DE"], check=True, capture_output=True)
    body = {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": open(csr).read()}}}
    try:
        cert = api("POST", "/v1/certificates", body)["data"]
    except SystemExit:
        # Apple erlaubt nur wenige Distributionszertifikate. Liefen kurz hintereinander zwei Builds, ist das
        # Zertifikat des vorigen noch da (bewusst, siehe purge). Ist es älter als 30 Minuten, ist der Upload
        # längst verarbeitet – dann darf es weg.
        print("Zertifikat-Limit erreicht – entferne CI-Zertifikate älter als 30 Minuten und versuche es erneut")
        purge(max_age_seconds=1800)
        cert = api("POST", "/v1/certificates", body)["data"]
    open(f"{workdir}/cert.der", "wb").write(base64.b64decode(cert["attributes"]["certificateContent"]))
    print("Zertifikat:", cert["attributes"].get("name"), cert["attributes"].get("expirationDate"))

    ids = api("GET", f"/v1/bundleIds?filter[identifier]={bundle_identifier}&limit=50")["data"]
    bundle = next((b for b in ids if b["attributes"]["identifier"] == bundle_identifier), None)
    if not bundle:
        print("Bundle-ID nicht gefunden:", bundle_identifier, file=sys.stderr); raise SystemExit(41)

    prof = api("POST", "/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": profile_name, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                          "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})["data"]
    open(f"{workdir}/profile.mobileprovision", "wb").write(base64.b64decode(prof["attributes"]["profileContent"]))
    json.dump({"certificate": cert["id"], "profile": prof["id"], "uuid": prof["attributes"]["uuid"],
               "name": prof["attributes"]["name"]}, open(f"{workdir}/ids.json", "w"))
    print("Profil:", prof["attributes"]["name"], prof["attributes"]["uuid"])

def extra(workdir, bundle_identifier, profile_name, display_name):
    """Profil für eine Erweiterung (z. B. Widgets) mit dem Zertifikat aus `create`; legt die Bundle-ID bei Bedarf an."""
    cert_id = json.load(open(f"{workdir}/ids.json"))["certificate"]
    ids = api("GET", f"/v1/bundleIds?filter[identifier]={bundle_identifier}&limit=50")["data"]
    bundle = next((b for b in ids if b["attributes"]["identifier"] == bundle_identifier), None)
    if not bundle:
        bundle = api("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": bundle_identifier, "name": display_name, "platform": "IOS"}}})["data"]
        print("Bundle-ID angelegt:", bundle_identifier)
    prof = api("POST", "/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": profile_name, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                          "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})["data"]
    open(f"{workdir}/{bundle_identifier}.mobileprovision", "wb").write(base64.b64decode(prof["attributes"]["profileContent"]))
    json.dump({"uuid": prof["attributes"]["uuid"], "name": prof["attributes"]["name"]},
              open(f"{workdir}/{bundle_identifier}.json", "w"))
    print("Profil:", prof["attributes"]["name"], prof["attributes"]["uuid"])

def cleanup(workdir):
    try:
        ids = json.load(open(f"{workdir}/ids.json"))
    except Exception:
        return
    for kind, key in (("profiles", "profile"), ("certificates", "certificate")):
        try:
            api("DELETE", f"/v1/{kind}/{ids[key]}")
            print("gelöscht:", kind, ids[key])
        except SystemExit:
            pass

def purge(max_age_seconds=7200):
    """Löscht Profile und Zertifikate früherer CI-Läufe (Name „Meeterz CI <Lauf>-<Unix-Zeit>“), die älter als 2 Stunden sind.
    Das Zertifikat bleibt nach dem Upload bewusst bestehen: Apple prüft die Signatur erst bei der Verarbeitung,
    ein sofort gelöschtes Zertifikat führt zu „ITMS-90035: Invalid Signature“."""
    now = time.time()
    for prof in api("GET", "/v1/profiles?limit=200").get("data", []):
        name = prof["attributes"].get("name", "")
        if not name.startswith("Meeterz CI "):
            continue
        try:
            created = int(name.rsplit("-", 1)[1])
        except (IndexError, ValueError):
            created = 0
        if now - created < max_age_seconds:
            print("behalten (zu jung):", name); continue
        try:
            certs = api("GET", f"/v1/profiles/{prof['id']}/certificates").get("data", [])
        except SystemExit:
            certs = []
        for kind, ident in [("profiles", prof["id"])] + [("certificates", c["id"]) for c in certs]:
            try:
                api("DELETE", f"/v1/{kind}/{ident}")
                print("gelöscht:", kind, ident, name)
            except SystemExit:
                pass

def status(bundle_identifier):
    """Zeigt die letzten Builds mit Verarbeitungsstatus und – falls vorhanden – die Fehler der Uploads."""
    def safe(path):
        try: return api("GET", path)
        except SystemExit: return {}
    app = safe(f"/v1/apps?filter[bundleId]={bundle_identifier}").get("data", [])
    if not app: print("App nicht gefunden"); return
    app_id = app[0]["id"]
    print(f"App {app_id}")
    for b in safe(f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=6").get("data", []):
        a = b["attributes"]
        print(f"Build {a.get('version')}: {a.get('processingState')}, min iOS {a.get('minOsVersion')}, hochgeladen {a.get('uploadedDate')}, abgelaufen={a.get('expired')}")
    for u in safe(f"/v1/apps/{app_id}/buildUploads?limit=6").get("data", []):
        a = u["attributes"]
        print(f"Upload {a.get('cfBundleVersion')}: {json.dumps(a.get('state'), ensure_ascii=False)}")

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "purge": purge(); raise SystemExit
    if cmd == "status": status(sys.argv[2]); raise SystemExit
    if cmd == "create": create(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "extra": extra(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == "cleanup": cleanup(sys.argv[2])
