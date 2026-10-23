#!/usr/bin/env python3
"""Schnelllader (DC, CCS, ab 50 kW) in Deutschland aus dem Ladesäulenregister der Bundesnetzagentur.

Quelle: https://www.bundesnetzagentur.de/ladesaeulenkarte – Lizenz CC BY 4.0, Namensnennung „Bundesnetzagentur.de“.
Aufruf: python3 tools/build_chargers.py <Ladesaeulenregister.csv> [Ausgabe.json]
Ergebnis: Standorte (benachbarte Ladeeinrichtungen zusammengefasst) als kompaktes JSON:
  {"meta": {...}, "sites": [[lat, lng, maxKW, Ladepunkte, "Name", "Betreiber", "Ort"], ...]}
"""
import csv, io, json, re, sys
from collections import defaultdict

src = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else "Meeterz/Resources/chargers-de.json"
raw = open(src, "rb").read()
for enc in ("utf-8-sig", "cp1252", "latin-1"):
    try:
        text = raw.decode(enc); break
    except UnicodeDecodeError:
        continue
lines = text.splitlines()
start = next(i for i, l in enumerate(lines) if "Breitengrad" in l)
reader = csv.reader(io.StringIO("\n".join(lines[start:])), delimiter=";")
header = [h.strip() for h in next(reader)]
print("Spalten:", header, file=sys.stderr)

def col(*names, required=True):
    for n in names:
        for i, h in enumerate(header):
            if h.lower().startswith(n.lower()):
                return i
    if required:
        sys.exit(f"Spalte fehlt: {names}")
    return None

c_lat, c_lng = col("Breitengrad"), col("Längengrad", "Laengengrad")
c_kw = col("Nennleistung Ladeeinrichtung")
c_op = col("Betreiber")
c_name = col("Anzeigename", required=False)
c_city = col("Ort")
c_status = col("Status", required=False)
c_points = col("Anzahl Ladepunkte", required=False)
plug_cols = [i for i, h in enumerate(header) if h.lower().startswith("steckertypen")]
plug_kw_cols = [i for i, h in enumerate(header) if h.lower().startswith("nennleistung stecker")]

def num(s):
    s = (s or "").strip().replace(".", "").replace(",", ".") if re.match(r"^\d{1,3}(\.\d{3})+(,\d+)?$", (s or "").strip()) else (s or "").strip().replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None

sites = defaultdict(lambda: {"kw": 0, "points": 0, "names": set(), "op": "", "city": ""})
rows = kept = 0
for r in reader:
    if len(r) < len(header) - 5:
        continue
    rows += 1
    if c_status is not None and r[c_status].strip().lower() not in ("", "in betrieb"):
        continue
    plugs = " ".join(r[i] for i in plug_cols if i < len(r))
    if "ccs" not in plugs.lower() and "combo" not in plugs.lower():
        continue
    lat, lng = num(r[c_lat]), num(r[c_lng])
    if lat is None or lng is None or not (47 < lat < 55.5 and 5.5 < lng < 15.5):
        continue
    # DC-Leistung: höchster Steckerwert mit CCS, sonst Leistung der Einrichtung
    kw = 0.0
    for pi, ki in zip(plug_cols, plug_kw_cols):
        if pi < len(r) and ki < len(r) and ("ccs" in r[pi].lower() or "combo" in r[pi].lower()):
            kw = max(kw, num(r[ki]) or 0)
    kw = kw or (num(r[c_kw]) or 0)
    if kw < 50:
        continue
    kept += 1
    key = (round(lat, 3), round(lng, 3), r[c_op].strip().lower()[:20])  # ~100 m, gleicher Betreiber
    s = sites[key]
    s["lat"], s["lng"] = lat, lng
    s["kw"] = max(s["kw"], kw)
    s["points"] += int(num(r[c_points]) or 1) if c_points is not None else 1
    s["op"] = r[c_op].strip()
    if c_name is not None and r[c_name].strip():
        s["names"].add(r[c_name].strip())
    s["city"] = r[c_city].strip()

out_sites = []
for s in sites.values():
    name = sorted(s["names"], key=len)[0] if s["names"] else s["op"]
    out_sites.append([round(s["lat"], 5), round(s["lng"], 5), round(s["kw"]), s["points"], name[:60], s["op"][:60], s["city"][:40]])
out_sites.sort()
meta = {"source": "Bundesnetzagentur.de – Ladesäulenregister", "license": "CC BY 4.0",
        "file": src.split("/")[-1], "sites": len(out_sites)}
json.dump({"meta": meta, "sites": out_sites}, open(out, "w"), ensure_ascii=False, separators=(",", ":"))
print(f"{rows} Zeilen, {kept} DC/CCS ≥ 50 kW, {len(out_sites)} Standorte", file=sys.stderr)
