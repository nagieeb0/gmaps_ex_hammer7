#!/usr/bin/env bash
# Live job postings for a senior O&M / facilities director in KSA.
#
# Source: LinkedIn's public jobs-guest endpoint — the only one of the four boards
# in job_search_report.md that answers a headless browser. Bayt and Indeed return
# a Cloudflare 403, NaukriGulf refuses the connection, Tanqeeb 404s its search
# path. Those stay manual-apply (see the report's section ج).
#
# Output: jobs/postings.jsonl (raw, append-only) + jobs/postings.csv (deduped).
# Re-runnable: dedupe is by LinkedIn job id, so repeat runs just top up.
set -uo pipefail

B="$HOME/.claude/skills/gstack/browse/dist/browse"
OUT_DIR="jobs"
RAW="$OUT_DIR/postings.jsonl"
mkdir -p "$OUT_DIR"

TITLES=(
  "maintenance manager"
  "maintenance director"
  "operation and maintenance manager"
  "facility management manager"
  "facilities manager"
  "MEP manager"
  "HVAC manager"
  "operations manager engineering"
  "head of facilities"
  "technical services manager"
  "plant manager"
  "مدير صيانة"
  "مدير تشغيل وصيانة"
  "مدير مرافق"
)

LOCATIONS=(
  "Jeddah, Saudi Arabia"
  "Riyadh, Saudi Arabia"
  "Makkah, Saudi Arabia"
  "Dammam, Saudi Arabia"
  "Saudi Arabia"
)

# Pull the fields straight off the guest-endpoint DOM. `location` is LinkedIn's
# own string ("Jiddah, Makkah, Saudi Arabia"), kept verbatim rather than
# normalised — the city spelling varies per posting and guessing loses data.
EXTRACT='JSON.stringify([...document.querySelectorAll("li")].map(li=>({
  title:li.querySelector("h3")?.innerText.trim()||"",
  company:li.querySelector("h4")?.innerText.trim()||"",
  location:li.querySelector(".job-search-card__location")?.innerText.trim()||"",
  posted:li.querySelector("time")?.getAttribute("datetime")||"",
  url:(li.querySelector("a")?.href||"").split("?")[0]
})).filter(j=>j.title&&j.url))'

urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }

total=0
for title in "${TITLES[@]}"; do
  for loc in "${LOCATIONS[@]}"; do
    kw=$(urlenc "$title"); lc=$(urlenc "$loc")
    # The guest endpoint pages 25 at a time and stops returning rows past the
    # end, so an empty page is the terminator — no total count is exposed.
    for start in 0 25 50 75; do
      url="https://www.linkedin.com/jobs-guest/jobs/api/seeMoreJobPostings/search?keywords=${kw}&location=${lc}&start=${start}"
      $B goto "$url" >/dev/null 2>&1 || continue
      rows=$($B js "$EXTRACT" 2>/dev/null | grep '^\[')
      if [ -z "$rows" ] || [ "$rows" = "[]" ]; then break; fi

      cnt=$(printf '%s' "$rows" | python3 -c '
import json,sys
rows=json.load(sys.stdin)
out=open(sys.argv[3],"a",encoding="utf-8")
for r in rows:
    r["query_title"]=sys.argv[1]; r["query_location"]=sys.argv[2]
    out.write(json.dumps(r,ensure_ascii=False)+"\n")
print(len(rows))
' "$title" "$loc" "$RAW")
      cnt=${cnt:-0}
      total=$((total + cnt))
      echo "  $title / $loc [$start] → $cnt"
      if [ "$cnt" -lt 25 ]; then break; fi
      sleep 1
    done
  done
done

echo ":: $total rows scraped → $RAW"

# Dedupe by job URL, classify by title, newest first.
python3 - "$RAW" "$OUT_DIR/postings.csv" "$OUT_DIR/postings-shortlist.csv" <<'PY'
import csv, json, re, sys

# LinkedIn's keyword match is fuzzy: a "maintenance manager" search returns
# frontend engineering managers and restaurant GMs. Classify on the title.
HIT = ["maintenance", "facilit", "facility", " fm ", "mep ", "hvac", "chiller",
       "air condition", "mechanical", "electromechanic", "plant manager",
       "operations manager", "operations director", "operation & maintenance",
       "o&m", "technical services", "technical manager", "engineering manager",
       "manager engineering", "engineering director", "director of engineering",
       "chief engineer", "utilities", "utility", "infrastructure",
       "asset management", "hard services", "building services",
       "property manager", "site manager", "workshop manager",
       # surfaced from the "unclear" bucket on review: BM/BMS are the building
       # -maintenance abbreviations, and construction managers at the big
       # contractors are the same hiring pool as O&M directors.
       "bm supervisor", "bms", "building management", "venue operations",
       "construction manager", "construction director", "plant supervisor",
       "صيانة", "مرافق", "تشغيل", "ميكانيك", "تكييف", "هندسي", "فني"]

# Checked BEFORE the hits, so a software "Engineering Manager, MAAS" is out
# even though "engineering manager" is a genuine facilities title elsewhere.
MISS = ["frontend", "front-end", "backend", "back-end", "software", "developer",
        "data scientist", "machine learning", " ai ", "accounting", "finance",
        "product manager", "marketing", "sales manager", "restaurant",
        "chef", "culinary", "human resources", "hr manager", "recruiter",
        "it manager", "information technology", "cyber", "qa manger",
        "quality assurance", "business development", "social media",
        "graphic", "content", "legal", "procurement manager", "supply chain",
        # software-org giveaways that ride in on "engineering manager"
        "maas", "devops", " sre ", "platform engineer", "cloud", "saas",
        "full stack", "fullstack", "enterprise solutions", "media", "recreation"]

def classify(title):
    t = " " + title.lower() + " "
    if any(m in t for m in MISS):
        return "off-target"
    if any(h in t for h in HIT):
        return "match"
    return "unclear"

seen, rows = {}, []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            j = json.loads(line)
        except json.JSONDecodeError:
            continue
        # Keep the first sighting but remember every query that surfaced it —
        # a posting hit by several title queries is a stronger match.
        key = j["url"]
        if key in seen:
            seen[key]["matched_queries"].add(j["query_title"])
        else:
            j["matched_queries"] = {j["query_title"]}
            seen[key] = j
            rows.append(j)

for r in rows:
    r["relevance"] = classify(r["title"])
    # Jeddah first: he lives there. LinkedIn spells it both ways.
    loc = r["location"].lower()
    r["city_rank"] = (0 if ("jeddah" in loc or "jiddah" in loc) else
                      1 if "makkah" in loc or "mecca" in loc else
                      2 if "riyadh" in loc else 3)

REL_RANK = {"match": 0, "unclear": 1, "off-target": 2}
rows.sort(key=lambda r: (REL_RANK[r["relevance"]], r["city_rank"],
                         -len(r["matched_queries"]), r.get("posted", "")),
          reverse=False)

HEADERS = ["relevance", "posted", "title", "company", "location", "match_count",
           "matched_queries", "apply_url"]

def write(path, data):
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(HEADERS)
        for r in data:
            w.writerow([r["relevance"], r.get("posted", ""), r["title"], r["company"],
                        r["location"], len(r["matched_queries"]),
                        " | ".join(sorted(r["matched_queries"])), r["url"]])

write(sys.argv[2], rows)
short = [r for r in rows if r["relevance"] == "match"]
write(sys.argv[3], short)

counts = {}
for r in rows:
    counts[r["relevance"]] = counts.get(r["relevance"], 0) + 1
print(f":: {len(rows)} unique postings → {sys.argv[2]}")
print(f"::   " + " · ".join(f"{k}: {v}" for k, v in sorted(counts.items())))
print(f":: {len(short)} on-target → {sys.argv[3]}")
PY
