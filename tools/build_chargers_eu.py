#!/usr/bin/env python3
"""Schnelllader (DC/CCS) in den Nachbarländern Deutschlands und Italien.

Quellen (so amtlich und detailliert wie möglich, sonst OpenStreetMap):
  FR  data.gouv.fr – Fichier consolidé IRVE (Licence Ouverte 2.0)
  CH  Bundesamt für Energie, data.geo.admin.ch (OICP, Open Government Data, Quellenangabe)
  NL, BE, LU, AT, CZ, PL, DK, IT  OpenStreetMap via Overpass (ODbL, © OpenStreetMap-Mitwirkende)
Ergebnis: Meeterz/Resources/chargers-eu.json  {"meta": {...}, "sites": [[lat, lng, kW, Ladepunkte, Name, Betreiber, Ort, Land], ...]}
kW = 0 heißt: Leistung unbekannt (die App rechnet dann vorsichtig mit 50 kW).
"""
import csv, gzip, io, json, re, sys, time, urllib.parse, urllib.request
from collections import defaultdict

OUT = sys.argv[1] if len(sys.argv) > 1 else "Meeterz/Resources/chargers-eu.json"
UA = {"User-Agent": "Meeterz-Ladeplanung/1.0 (github.com/GianlucaKo95/Meeterz)"}
stats = {}

def get(url, data=None, timeout=600):
    req = urllib.request.Request(url, data=data, headers=UA)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                body = r.read()
                return gzip.decompress(body) if body[:2] == b"\x1f\x8b" else body
        except Exception as e:
            print(f"  Versuch {attempt + 1} fehlgeschlagen: {e}", file=sys.stderr)
            time.sleep(30 * (attempt + 1))
    raise RuntimeError(f"nicht erreichbar: {url}")

def num(v):
    if v is None:
        return None
    m = re.search(r"(-?\d+(?:[.,]\d+)?)", str(v))   # Vorzeichen! (Westfrankreich hat negative Längen)
    return float(m.group(1).replace(",", ".")) if m else None

def kw(v):
    """„150 kW“, „150000 W“, „150“ → 150"""
    if v is None:
        return None
    s = str(v).lower()
    vals = [float(x.replace(",", ".")) for x in re.findall(r"\d+(?:[.,]\d+)?", s)]
    if not vals:
        return None
    x = max(vals)
    if "kw" in s:
        return x
    if re.search(r"\bw\b", s) or x > 1000:
        return x / 1000
    return x

# Grobe Landesgrenzen (inkl. Korsika/Sizilien/Sardinien) – fängt vertauschte oder fehlerhafte Koordinaten ab
BOUNDS = {"FR": (41.2, 51.2, -5.3, 9.7), "CH": (45.7, 47.9, 5.9, 10.6), "NL": (50.7, 53.7, 3.2, 7.3),
          "BE": (49.4, 51.6, 2.5, 6.5), "LU": (49.4, 50.2, 5.7, 6.6), "AT": (46.3, 49.1, 9.5, 17.2),
          "CZ": (48.5, 51.1, 12.0, 18.9), "PL": (49.0, 54.9, 14.1, 24.2), "DK": (54.5, 57.8, 8.0, 15.2),
          "IT": (35.4, 47.1, 6.6, 18.6)}

sites = {}
def add(country, lat, lng, power, points, name, op, city):
    if lat is None or lng is None:
        return
    b = BOUNDS.get(country)
    if b and not (b[0] <= lat <= b[1] and b[2] <= lng <= b[3]):
        return
    if power and power < 50:
        return
    key = (country, round(lat, 3), round(lng, 3), (op or "").lower()[:20])
    s = sites.get(key)
    if s:
        s[2] = max(s[2], power or 0)
        s[3] += points or 1
        return
    sites[key] = [round(lat, 5), round(lng, 5), round(power or 0), points or 1,
                  (name or op or "")[:60].strip(), (op or "")[:60].strip(), (city or "")[:40].strip(), country]

# --- Frankreich: IRVE konsolidiert -------------------------------------------------------------
def france():
    meta = json.loads(get("https://www.data.gouv.fr/api/1/datasets/fichier-consolide-des-bornes-de-recharge-pour-vehicules-electriques/"))
    res = [r for r in meta["resources"] if (r.get("format") or "").lower() == "csv"]
    res.sort(key=lambda r: ("consolid" not in (r.get("title") or "").lower(), r.get("last_modified") or ""), reverse=False)
    url = res[0]["url"]
    print("FR:", res[0].get("title"), url, file=sys.stderr)
    text = get(url).decode("utf-8-sig", errors="replace")
    rows = csv.DictReader(io.StringIO(text), delimiter="," if text[:2000].count(",") > text[:2000].count(";") else ";")
    n = 0
    for r in rows:
        ccs = (r.get("prise_type_combo_ccs") or "").strip().lower() in ("true", "1", "oui", "vrai")
        if not ccs:
            continue
        lat = num(r.get("consolidated_latitude")); lng = num(r.get("consolidated_longitude"))
        if lat is None or lng is None:
            xy = re.findall(r"-?\d+\.\d+", r.get("coordonneesXY") or "")
            if len(xy) >= 2:
                lng, lat = float(xy[0]), float(xy[1])
        p = kw(r.get("puissance_nominale"))
        # puissance_nominale ist meist in kW; Werte > 1000 sind W
        add("FR", lat, lng, p, 1, r.get("nom_station"), r.get("nom_operateur") or r.get("nom_enseigne"),
            r.get("consolidated_commune") or r.get("commune") or "")
        n += 1
    stats["FR"] = n

# --- Schweiz: BFE (OICP) ------------------------------------------------------------------------
def switzerland():
    data = json.loads(get("https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/data/oicp/ch.bfe.ladestellen-elektromobilitaet.json"))
    blocks = data.get("EVSEData", []) if isinstance(data, dict) else data
    n = errors = 0
    for block in blocks:
        op_name = block.get("OperatorName") if isinstance(block, dict) else None
        for rec in (block.get("EVSEDataRecord") or []) if isinstance(block, dict) else []:
            try:
                if "CH_SAMPLE" not in stats:
                    stats["CH_SAMPLE"] = json.dumps(rec, ensure_ascii=False)[:1500]
                plugs = json.dumps(rec.get("Plugs") or rec.get("plugs") or "").lower()
                if "ccs" not in plugs and "combo" not in plugs:
                    continue
                geo = rec.get("GeoCoordinates") or {}
                g = geo.get("Google") or geo.get("DecimalDegree") or geo
                parts = re.findall(r"-?\d+\.\d+", json.dumps(g))
                if len(parts) < 2:
                    continue
                lat, lng = float(parts[0]), float(parts[1])
                if isinstance(g, dict) and "Longitude" in g and "Latitude" in g:
                    lat, lng = float(g["Latitude"]), float(g["Longitude"])
                power = 0.0
                for f in rec.get("ChargingFacilities") or []:
                    if isinstance(f, dict):
                        power = max(power, kw(f.get("Power") or f.get("power")) or 0)
                    else:
                        power = max(power, kw(f) or 0)
                names = rec.get("ChargingStationNames") or rec.get("ChargingStationName") or []
                if isinstance(names, list) and names:
                    first = names[0]
                    name = first.get("value") if isinstance(first, dict) else str(first)
                elif isinstance(names, dict):
                    name = names.get("value")
                else:
                    name = str(names) if names else rec.get("ChargingStationId")
                addr = rec.get("Address") or {}
                add("CH", lat, lng, power, 1, name, op_name, addr.get("City") if isinstance(addr, dict) else "")
                n += 1
            except Exception as e:
                errors += 1
                stats.setdefault("CH_ERROR", repr(e))
    stats["CH"] = n
    stats["CH_ERRORS"] = errors

# --- OpenStreetMap ----------------------------------------------------------------------------
OSM_COUNTRIES = ["NL", "BE", "LU", "AT", "CZ", "PL", "DK", "IT"]

def osm(country):
    q = f"""[out:json][timeout:600];
area["ISO3166-1"="{country}"][admin_level=2]->.a;
nwr["amenity"="charging_station"]["socket:type2_combo"](area.a);
out center tags;"""
    data = json.loads(get("https://overpass-api.de/api/interpreter", data=urllib.parse.urlencode({"data": q}).encode()))
    n = 0
    for e in data.get("elements", []):
        t = e.get("tags", {})
        if t.get("socket:type2_combo") in ("no", "0"):
            continue
        if t.get("access") in ("private", "no", "customers") and t.get("access") != "customers":
            continue
        lat = e.get("lat") or (e.get("center") or {}).get("lat")
        lng = e.get("lon") or (e.get("center") or {}).get("lon")
        power = kw(t.get("socket:type2_combo:output")) or kw(t.get("charging_station:output")) or kw(t.get("maxpower"))
        points = int(num(t.get("socket:type2_combo")) or num(t.get("capacity")) or 1)
        name = t.get("name") or t.get("brand")
        op = t.get("operator") or t.get("brand") or t.get("network") or ""
        city = t.get("addr:city") or ""
        add(country, lat, lng, power, points, name, op, city)
        n += 1
    stats[country] = n
    time.sleep(20)   # Overpass schonen

for job, fn in [("FR", france), ("CH", switzerland)] + [(c, lambda c=c: osm(c)) for c in OSM_COUNTRIES]:
    try:
        print("==", job, file=sys.stderr)
        fn()
    except Exception as e:
        print(f"!! {job} fehlgeschlagen: {e}", file=sys.stderr)
        stats[job] = f"Fehler: {e}"

out = sorted(sites.values())
per = defaultdict(int)
for s in out:
    per[s[7]] += 1
meta = {"sources": {"FR": "data.gouv.fr IRVE (Licence Ouverte 2.0)", "CH": "Bundesamt für Energie (opendata.swiss)",
                    "OSM": "© OpenStreetMap-Mitwirkende (ODbL)"},
        "sites": len(out), "per_country": per, "raw": stats}
json.dump({"meta": meta, "sites": out}, open(OUT, "w"), ensure_ascii=False, separators=(",", ":"))
print(json.dumps(meta, ensure_ascii=False), file=sys.stderr)
