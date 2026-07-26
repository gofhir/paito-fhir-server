#!/usr/bin/env bash
# ==============================================================================
# paito FHIR Server — Search examples (all parameter types & modifiers)
# ==============================================================================
# Derived from the proven e2e smoke scripts:
#   go-fhir-server/scripts/e2e-smoke.sh          (search by string/token/date/reference, _revinclude)
#   go-fhir-server/scripts/e2e-advanced-smoke.sh (sort, paging, date prefixes, modifiers, _include)
#
# Demonstrates: string / token / date / reference / quantity / composite params,
# :exact / :contains / :not modifiers, _include / _revinclude, _has (reverse
# chaining), chained search, _sort, _count paging (link[next]), _summary, _elements.
#
# Requires: curl, python3. Launch the stack first (see README.md):
#   docker compose -f docker-compose.yml up -d
#
# Usage:
#   bash run.sh                       # against http://localhost:3500/fhir/r4
#   BASE_URL=http://host:3500/fhir/r4 bash run.sh
# ==============================================================================
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

G="\033[32m"; C="\033[36m"; B="\033[1m"; R="\033[31m"; N="\033[0m"
step()  { printf "\n${B}${C}== %s ==${N}\n" "$1"; }
demo()  { printf "${B}-- %s${N}\n" "$1"; }
ok()    { printf "${G}OK${N}  %s\n" "$1"; }
die()   { printf "${R}FAIL${N} %s\n" "$1" >&2; exit 1; }

# GET a search and print total; args: <url> <label>
# Appends _total=accurate so the printed count is exact regardless of the
# server's default total mode (which defaults to "estimate").
show_total() {
  local url=$1 label=$2 body total sep='&'
  [[ "$url" == *\?* ]] || sep='?'
  body=$(curl -sS "${url}${sep}_total=accurate")
  total=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total','?'))")
  ok "$label -> total=$total"
}

# --- Pre-flight -------------------------------------------------------------
step "Pre-flight: server reachable"
curl -fsS --max-time 5 "$BASE_URL/metadata" >/dev/null \
  || die "server not reachable at $BASE_URL — run: docker compose -f docker-compose.yml up -d"
ok "$BASE_URL/metadata responds"

# --- Seed data (idempotent via conditional create / If-None-Exist) ----------
# If-None-Exist makes a repeat POST return 200 + same id instead of duplicating.
step "Seed: 3 Patients (SearchDemo, born 1985/1990/1995) + 1 Observation"
declare -a PIDS
i=0
for mrn in SD-001 SD-002 SD-003; do
  i=$((i+1))
  body=$(curl -sS -X POST "$BASE_URL/Patient" \
    -H "Content-Type: application/fhir+json" \
    -H "If-None-Exist: identifier=http://hospital.example/mrn|$mrn" \
    --data-binary @"$DIR/patient-$i.json")
  pid=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
  [[ -n "$pid" ]] || die "could not seed Patient $mrn"
  PIDS[$i]=$pid
  ok "Patient $mrn -> id=$pid"
done
PID1="${PIDS[1]}"

# Observation for Patient 1 (heart rate 72 /min, LOINC 8867-4)
sed "s/__PATIENT_ID__/$PID1/" "$DIR/observation.json" > /tmp/paito-obs.json
obs_body=$(curl -sS -X POST "$BASE_URL/Observation" \
  -H "Content-Type: application/fhir+json" \
  -H "If-None-Exist: subject=Patient/$PID1&code=http://loinc.org|8867-4" \
  --data-binary @/tmp/paito-obs.json)
OBS_ID=$(echo "$obs_body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
ok "Observation -> id=$OBS_ID (subject=Patient/$PID1)"

# ============================================================================
# 1. STRING search + modifiers (:exact, :contains)
# ============================================================================
step "1. String parameter + modifiers"

demo "family=SearchDemo  (case-insensitive prefix match) -> 3"
show_total "$BASE_URL/Patient?family=SearchDemo" "family=SearchDemo"

demo "given:exact=Ana  (exact, case-sensitive) -> 1"
show_total "$BASE_URL/Patient?given:exact=Ana" "given:exact=Ana"

demo "given:exact=an  (:exact must NOT prefix-match) -> 0"
show_total "$BASE_URL/Patient?given:exact=an" "given:exact=an"

demo "family:contains=archDem  (substring anywhere) -> 3"
show_total "$BASE_URL/Patient?family:contains=archDem" "family:contains=archDem"

# ============================================================================
# 2. TOKEN search + modifiers
# ============================================================================
step "2. Token parameter (system|code, code-only) + :not"

demo "gender=female  -> 2 (Ana + Carla)"
show_total "$BASE_URL/Patient?gender=female" "gender=female"

demo "gender:not=female  -> 1 (Bruno)"
show_total "$BASE_URL/Patient?family=SearchDemo&gender:not=female" "gender:not=female"

demo "identifier=http://hospital.example/mrn|SD-002  (system|value) -> 1"
show_total "$BASE_URL/Patient?identifier=http://hospital.example/mrn|SD-002" "identifier system|value"

demo "Observation code=http://loinc.org|8867-4 -> 1"
show_total "$BASE_URL/Observation?code=http://loinc.org|8867-4" "code loinc|8867-4"

# ============================================================================
# 3. DATE search + prefixes (gt/lt/ge/le) + ranges
# ============================================================================
step "3. Date parameter + comparison prefixes"

demo "birthdate=1990-06-15  (exact) -> 1"
show_total "$BASE_URL/Patient?family=SearchDemo&birthdate=1990-06-15" "birthdate exact"

demo "birthdate=gt1988-01-01  (after) -> 2 (1990 + 1995)"
show_total "$BASE_URL/Patient?family=SearchDemo&birthdate=gt1988-01-01" "birthdate gt1988"

demo "birthdate=lt1992-01-01  (before) -> 2 (1985 + 1990)"
show_total "$BASE_URL/Patient?family=SearchDemo&birthdate=lt1992-01-01" "birthdate lt1992"

demo "birthdate=ge1989 & birthdate=le1992  (range) -> 1 (1990)"
show_total "$BASE_URL/Patient?family=SearchDemo&birthdate=ge1989&birthdate=le1992" "birthdate range"

# ============================================================================
# 4. REFERENCE + QUANTITY + COMPOSITE (Observation)
# ============================================================================
step "4. Reference, quantity and composite parameters"

demo "subject=Patient/\$PID1  (reference) -> 1"
show_total "$BASE_URL/Observation?subject=Patient/$PID1" "subject=Patient/$PID1"

demo "value-quantity=gt60  (quantity, numeric compare) -> 1"
show_total "$BASE_URL/Observation?value-quantity=gt60" "value-quantity=gt60"

demo "value-quantity=72||/min  (quantity value + unit) -> 1"
show_total "$BASE_URL/Observation?value-quantity=72||/min" "value-quantity 72||/min"

demo "code-value-quantity=http://loinc.org|8867-4\$gt60  (composite, same element) -> 1"
show_total "$BASE_URL/Observation?code-value-quantity=http://loinc.org|8867-4\$gt60" "composite code-value-quantity"

# ============================================================================
# 5. CHAINED search + reverse chaining (_has)
# ============================================================================
step "5. Chained (forward) and _has (reverse) search"

demo "Observation?subject:Patient.family=SearchDemo  (chained) -> 1"
show_total "$BASE_URL/Observation?subject:Patient.family=SearchDemo" "chained subject:Patient.family"

demo "Patient?_has:Observation:subject:code=http://loinc.org|8867-4  (_has) -> 1 (Ana)"
show_total "$BASE_URL/Patient?_has:Observation:subject:code=http://loinc.org|8867-4" "_has Observation.code"

# ============================================================================
# 6. _include / _revinclude
# ============================================================================
step "6. _include (forward) and _revinclude (reverse)"

demo "Observation?subject=Patient/\$PID1&_include=Observation:subject  -> 1 match + 1 include"
body=$(curl -sS "$BASE_URL/Observation?subject=Patient/$PID1&_include=Observation:subject")
matches=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for e in d.get('entry',[]) if e.get('search',{}).get('mode')=='match'))")
includes=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for e in d.get('entry',[]) if e.get('search',{}).get('mode')=='include'))")
[[ "$matches" == "1" && "$includes" == "1" ]] && ok "_include -> match=$matches include=$includes" || die "_include match=$matches include=$includes (want 1+1)"

demo "Patient?_id=\$PID1&_revinclude=Observation:subject  -> Patient + its Observation"
body=$(curl -sS "$BASE_URL/Patient?_id=$PID1&_revinclude=Observation:subject")
echo "$body" | grep -q '"resourceType":"Observation"' && ok "_revinclude pulled the Observation" || die "_revinclude did not pull Observation"

# ============================================================================
# 7. _sort, _count paging (link[next])
# ============================================================================
step "7. Sorting and cursor/offset paging"

demo "_sort=-birthdate  (descending: youngest first -> 1995)"
first=$(curl -sS "$BASE_URL/Patient?family=SearchDemo&_sort=-birthdate" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['entry'][0]['resource']['birthDate'])")
[[ "$first" == "1995-06-15" ]] && ok "_sort=-birthdate first=$first" || die "_sort=-birthdate first=$first (want 1995-06-15)"

demo "_sort=birthdate  (ascending: oldest first -> 1985)"
first=$(curl -sS "$BASE_URL/Patient?family=SearchDemo&_sort=birthdate" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['entry'][0]['resource']['birthDate'])")
[[ "$first" == "1985-06-15" ]] && ok "_sort=birthdate first=$first" || die "_sort=birthdate first=$first (want 1985-06-15)"

demo "_count=2  -> page 1 of 2 entries + link[next]"
body=$(curl -sS "$BASE_URL/Patient?family=SearchDemo&_count=2")
returned=$(echo "$body" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('entry',[])))")
next=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); u=[l['url'] for l in d.get('link',[]) if l['relation']=='next']; print(u[0] if u else '')")
[[ "$returned" == "2" && -n "$next" ]] && ok "page 1 entries=$returned, link[next] present" || die "paging page1=$returned next=$next"

demo "follow link[next] -> page 2 (remaining entry)"
returned=$(curl -sS "$next" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('entry',[])))")
[[ "$returned" -ge 1 ]] && ok "page 2 entries=$returned" || die "page 2 returned $returned"

# ============================================================================
# 8. Result control: _summary, _elements
# ============================================================================
step "8. Result shaping: _summary, _elements"

demo "_summary=count  -> total only, no entries"
body=$(curl -sS "$BASE_URL/Patient?family=SearchDemo&_summary=count")
total=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total','?'))")
ok "_summary=count total=$total"

demo "_elements=name,birthDate  -> only requested elements (plus id/meta)"
curl -sS "$BASE_URL/Patient?family=SearchDemo&_elements=name,birthDate&_count=1" \
  | python3 -c "import sys,json; e=json.load(sys.stdin)['entry'][0]['resource']; print('kept keys:', sorted(e.keys()))"

# ============================================================================
# 9. Combined: filter + sort + limit in one request
# ============================================================================
step "9. Composed query: filter + sort + limit"
demo "family=SearchDemo & birthdate=gt1988 & _sort=-birthdate & _count=1 -> 1995 first"
body=$(curl -sS "$BASE_URL/Patient?family=SearchDemo&birthdate=gt1988-01-01&_sort=-birthdate&_count=1")
first=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin)['entry'][0]['resource']['birthDate'])")
[[ "$first" == "1995-06-15" ]] && ok "composed query first=$first" || die "composed query first=$first (want 1995-06-15)"

step "All search examples completed"
