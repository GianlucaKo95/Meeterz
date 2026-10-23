#!/usr/bin/env python3
"""Erzeugt Meeterz/Resources/ev-vehicles.json aus Open EV Data (https://github.com/KilowattApp/open-ev-data).

Aufruf: python3 tools/build_ev_vehicles.py <pfad/zu/open-ev-data/data/ev-data.json>

- nur Autos (keine Motorräder)
- Einträge mit geschätzter Ladekurve (DC-Leistung = Batteriegröße, automatisch erzeugt) nur, wenn es für
  Marke und Batteriegröße keinen gepflegten Eintrag gibt; sie werden als „geschätzt“ markiert
- doppelte Einträge (gleiche Marke, Modell, Variante, Jahr) zusammengefasst
"""
import json, sys, re

src = json.load(open(sys.argv[1]))
rows = [v for v in src["data"] if v.get("vehicle_type", "car") in ("car", "microcar")]

def estimated(v):
    dc = v.get("dc_charger") or {}
    return dc.get("max_power") == v.get("usable_battery_size")

def nice(model):
    model = model.strip().rstrip(".")
    if model and model == model.lower() and not re.match(r"^[a-z]+-", model):
        model = " ".join(w if any(c.isdigit() for c in w) else w.capitalize() for w in model.split())
    return re.sub(r"\s+", " ", model)

curated = {(v["brand"], round(v.get("usable_battery_size") or 0)) for v in rows if not estimated(v)}
out, seen = [], set()
for v in rows:
    est = estimated(v)
    battery = v.get("usable_battery_size")
    cons = (v.get("energy_consumption") or {}).get("average_consumption")
    if not battery or not cons:
        continue
    if est and (v["brand"], round(battery)) in curated:
        continue
    model, variant = nice(v["model"]), (v.get("variant") or "").strip()
    # Automatisch erfasste Einträge mit nichtssagendem Namen („Ev“, „R“) weglassen
    if est and len(model) < 4:
        continue
    key = (v["brand"].lower(), model.lower(), variant.lower(), v.get("release_year"))
    if key in seen:
        continue
    seen.add(key)
    dc = v.get("dc_charger") or {}
    out.append({
        "id": v["id"],
        "brand": v["brand"].strip(),
        "model": model,
        "variant": variant,
        "year": v.get("release_year"),
        "battery": battery,                        # nutzbar, kWh
        "consumption": cons,                       # kWh/100 km
        "dcMax": dc.get("max_power"),              # kW
        "curve": [[p["percentage"], p["power"]] for p in dc.get("charging_curve") or []],
        "ports": (dc.get("ports") or []),
        "estimated": est,
    })

out.sort(key=lambda v: (v["brand"].lower(), v["model"].lower(), v["variant"].lower(), -(v["year"] or 0)))
meta = {"source": "Open EV Data (https://github.com/KilowattApp/open-ev-data)", "license": "MIT with attribution",
        "updated": src.get("meta", {}).get("updated_at"), "count": len(out)}
json.dump({"meta": meta, "vehicles": out}, open("Meeterz/Resources/ev-vehicles.json", "w"),
          ensure_ascii=False, separators=(",", ":"))
print(meta, len({v["brand"] for v in out}), "Marken")
