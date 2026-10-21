#!/usr/bin/env python3
"""Paginate the Riyadh catering leads CSV into physically-clustered pages of 100.

Strategy
--------
1. Read all lead rows with valid lat/long. Split into Riyadh-metro leads
   (inside a Riyadh bounding box) and genuine global outliers (e.g. New York,
   India) that share the same `input_id` zone scheme but are physically far.
2. Bucket every lead into a 2 km geographic grid cell, sorting each cell's leads
   by lead_class (A+ -> A -> B -> C, then review_count desc).
3. Build pages one at a time by *seed-and-grow*: each page seeds from the
   highest-priority unassigned lead and grows by always pulling the nearest
   remaining grid cell (closest to the seed). This keeps each page's 100 leads
   in one contiguous local area with the smallest possible radius.
4. Within a page, re-sort by lead_class -> review_count and assign
   rank_in_page, preserving the existing A+ -> C ranking.
5. Emit one CSV per page (page_001.csv ...) plus manifest.csv / README.md.
   Outlier leads are isolated into their own pages (labelled by country) since
   they cannot physically sit with Riyadh leads.

Columns added to every page: page_number, rank_in_page, page_area_label,
page_center_lat, page_center_lon, page_radius_km.
"""
import csv
import json
import math
import os
import re
import statistics
from collections import Counter

SRC = "riyadh-catering-leads (Copy 1).csv"
OUT_DIR = "leads_pages"
PAGE_SIZE = 100
CELL_KM = 2.0  # grid cell side
RIYADH_BBOX = (24.0, 25.5, 46.2, 47.2)  # lat_min, lat_max, lon_min, lon_max

CLASS_ORDER = {"A+ (Hot Lead)": 0, "A (Warm Lead)": 1, "B (Potential)": 2, "C (Cold Lead)": 3}


def class_rank(lead_class):
    return CLASS_ORDER.get(lead_class, 9)


def km_per_deg_lat():
    return 111.0


def km_per_deg_lon(lat):
    return 111.0 * math.cos(math.radians(lat))


def read_rows(path):
    rows = []
    with open(path, encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        header = reader.fieldnames
        for row in reader:
            try:
                lat = float(row["latitude"])
                lon = float(row["longitude"])
            except (ValueError, TypeError, KeyError):
                continue
            rows.append((row, lat, lon))
    return header, rows


def haversine(lat1, lon1, lat2, lon2):
    R = 6371.0
    p1 = math.radians(lat1); p2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1); dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(a))


def best_point_key(row):
    try:
        rc = int(float(row.get("review_count") or 0))
    except (ValueError, TypeError):
        rc = 0
    return (class_rank(row.get("lead_class", "")), -rc)


def country_of(row):
    raw = row.get("complete_address", "")
    if not raw:
        return "unknown"
    m = re.search(r'"country"\s*:\s*"([^"]+)"', raw)
    return m.group(1) if m else "unknown"


def build_cells(rows):
    cells = {}
    for row, lat, lon in rows:
        lat_step = CELL_KM / km_per_deg_lat()
        lon_step = CELL_KM / km_per_deg_lon(lat)
        ci = int(math.floor(lat / lat_step))
        cj = int(math.floor(lon / lon_step))
        key = (ci, cj)
        clat = (ci + 0.5) * lat_step
        clon = (cj + 0.5) * lon_step
        cell = cells.setdefault(key, {"points": [], "clat": clat, "clon": clon})
        cell["points"].append((row, lat, lon))
    for key in cells:
        cells[key]["points"].sort(key=lambda it: best_point_key(it[0]))
    return cells


def find_seed(cells):
    best = None
    for key, cell in cells.items():
        if not cell["points"]:
            continue
        cand = best_point_key(cell["points"][0][0])
        if best is None or cand < best[0]:
            best = (cand, key)
    return best[1] if best else None


def build_page(cells):
    seed_key = find_seed(cells)
    if seed_key is None:
        return None
    seed = cells[seed_key]
    page = []
    while len(page) < PAGE_SIZE:
        nearest = None
        nearest_d = None
        for ck, cell in cells.items():
            if not cell["points"]:
                continue
            d = haversine(seed["clat"], seed["clon"], cell["clat"], cell["clon"])
            if nearest_d is None or d < nearest_d:
                nearest_d = d
                nearest = ck
        if nearest is None:
            break
        cell = cells[nearest]
        need = PAGE_SIZE - len(page)
        taken = cell["points"][:need]
        page.extend(taken)
        del cell["points"][:need]
        if not cell["points"]:
            del cells[nearest]
    if not page:
        return None
    page.sort(key=lambda it: best_point_key(it[0]))
    return page


def main():
    header, rows = read_rows(SRC)
    print(f"Read {len(rows)} rows with valid coordinates")

    riyadh_rows = []
    outside_rows = []
    for row, lat, lon in rows:
        la_min, la_max, lo_min, lo_max = RIYADH_BBOX
        if la_min <= lat <= la_max and lo_min <= lon <= lo_max:
            riyadh_rows.append((row, lat, lon))
        else:
            outside_rows.append((row, lat, lon))
    print(f"Riyadh-metro leads: {len(riyadh_rows)} | global outliers: {len(outside_rows)}")

    out_header = ["page_number", "rank_in_page", "page_area_label", "page_center_lat",
                  "page_center_lon", "page_radius_km"] + header
    os.makedirs(OUT_DIR, exist_ok=True)

    manifest_rows = []
    page_number = 0

    def flush_page(items, area_label_fn, region_tag):
        nonlocal page_number
        page_number += 1
        lats = [it[1] for it in items]
        lons = [it[2] for it in items]
        clat = statistics.mean(lats)
        clon = statistics.mean(lons)
        radius = max(haversine(clat, clon, lat, lon) for _, lat, lon in items)
        area_label = area_label_fn(items)
        pg = f"page_{page_number:03d}"
        path = os.path.join(OUT_DIR, pg + ".csv")
        with open(path, "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(out_header)
            for rank, (row, lat, lon) in enumerate(items, start=1):
                w.writerow([page_number, rank, area_label,
                            round(clat, 6), round(clon, 6), round(radius, 3)]
                           + [row.get(h, "") for h in header])
        manifest_rows.append({
            "page_number": page_number, "region": region_tag, "area_label": area_label,
            "rows": len(items), "center_lat": round(clat, 6), "center_lon": round(clon, 6),
            "radius_km": round(radius, 3),
            "a_plus": sum(1 for it in items if it[0].get("lead_class") == "A+ (Hot Lead)"),
            "a": sum(1 for it in items if it[0].get("lead_class") == "A (Warm Lead)"),
            "b": sum(1 for it in items if it[0].get("lead_class") == "B (Potential)"),
            "c": sum(1 for it in items if it[0].get("lead_class") == "C (Cold Lead)"),
            "file": pg + ".csv",
        })
        print(f"{pg}: {len(items):>3} leads | {region_tag} | area={area_label} | "
              f"radius={radius:7.2f} km | A+={manifest_rows[-1]['a_plus']} "
              f"A={manifest_rows[-1]['a']} B={manifest_rows[-1]['b']} C={manifest_rows[-1]['c']}")

    # ---- Riyadh pages ----
    cells = build_cells(riyadh_rows)
    print(f"Riyadh grid cells: {len(cells)}")

    def riyadh_area(items):
        zones = Counter(it[0].get("input_id", "") for it in items)
        return zones.most_common(1)[0][0] if zones else "riyadh"

    while True:
        page = build_page(cells)
        if page is None:
            break
        flush_page(page, riyadh_area, "riyadh")

    # ---- Global outliers: group by country, then paginate each group separately
    # so every outlier page is a small, honest per-country cluster. ----
    if outside_rows:
        by_country = {}
        for item in outside_rows:
            by_country.setdefault(country_of(item[0]), []).append(item)
        print(f"Outlier countries: {len(by_country)}")
        for country, crows in sorted(by_country.items(), key=lambda kv: -len(kv[1])):
            ccells = build_cells(crows)
            print(f"  {country}: {len(crows)} leads in {len(ccells)} cells")

            def outside_area(items, _c=country):
                return f"global-outlier:{_c}"

            while True:
                page = build_page(ccells)
                if page is None:
                    break
                flush_page(page, outside_area, "global-outlier")

    with open(os.path.join(OUT_DIR, "manifest.csv"), "w", encoding="utf-8", newline="") as f:
        mh = ["page_number", "region", "area_label", "rows", "center_lat", "center_lon",
              "radius_km", "a_plus", "a", "b", "c", "file"]
        w = csv.DictWriter(f, fieldnames=mh)
        w.writeheader()
        w.writerows(manifest_rows)

    with open(os.path.join(OUT_DIR, "README.md"), "w", encoding="utf-8") as f:
        f.write("# Paginated Riyadh Catering Leads\n\n")
        f.write(f"- Source: `{SRC}`\n")
        f.write(f"- Total leads: {len(rows)} (Riyadh-metro: {len(riyadh_rows)}, "
                f"global outliers: {len(outside_rows)})\n")
        f.write(f"- Pages: {page_number} (Riyadh pages hold up to {PAGE_SIZE} leads each; "
                "outlier pages hold whatever clustered locally by country).\n")
        f.write(f"- Grid cell: {CELL_KM} km; each page grows from its hottest remaining lead "
                "by pulling the nearest grid cells, so members share one contiguous area.\n")
        f.write("- Ranking: within each page leads are sorted by `lead_class` A+ -> A -> B -> C, "
                "then review_count desc; `rank_in_page` is that position.\n")
        f.write("- `manifest.csv` summarizes every page (region, area, center, radius_km, "
                "A+/A/B/C counts).\n")
        f.write("- `page_radius_km` proves clustering tightness. Riyadh pages typically span "
                "2-5 km; a few sparse tail pages reach farther across the metro; outlier pages "
                "are grouped by country.\n")

    print(f"\nDone. {page_number} pages written to ./{OUT_DIR}/")


if __name__ == "__main__":
    main()
