#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

API_BASE="${API_BASE:-http://localhost:8080}"
START_LON=113.887401
START_LAT=22.535316
END_LON=113.886131
END_LAT=22.534781

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

echo "=== Park routing smoke tests (real park data) ==="

echo "--- Database checks ---"
WAY_COUNT="$(docker compose exec -T db psql -U postgres -d park_routing -tAc "SELECT COUNT(*) FROM park_ways;")"
[[ "$WAY_COUNT" == "348" ]] || fail "expected 348 park_ways rows, got $WAY_COUNT"
pass "park_ways count is 348"

MISSING_TOPOLOGY="$(docker compose exec -T db psql -U postgres -d park_routing -tAc \
  "SELECT COUNT(*) FROM park_ways WHERE source IS NULL OR target IS NULL;")"
[[ "$MISSING_TOPOLOGY" == "0" ]] || fail "topology incomplete: $MISSING_TOPOLOGY edges missing source/target"
pass "topology complete"

echo "--- SQL routing ---"
ROUTE_DISTANCE="$(docker compose exec -T db psql -U postgres -d park_routing -tAc \
  "SELECT distance_m FROM route_between_points($START_LON, $START_LAT, $END_LON, $END_LAT, 'walk', 'wgs84');")"
python3 - "$ROUTE_DISTANCE" <<'PY'
import sys
distance = float(sys.argv[1])
if distance <= 0:
    raise SystemExit(f"expected distance_m > 0, got {distance}")
print(f"route distance_m={distance}")
PY
pass "route_between_points returned distance_m > 0"

NAV_STATS="$(docker compose exec -T db psql -U postgres -d park_routing -tAc \
  "SELECT distance_m, jsonb_array_length(path_polyline), jsonb_array_length(navigation_steps)
   FROM navigate_between_points($START_LON, $START_LAT, $END_LON, $END_LAT, 'walk', 'wgs84');")"
IFS='|' read -r NAV_DISTANCE POLYLINE_LEN STEPS_LEN <<< "$NAV_STATS"
python3 - "$NAV_DISTANCE" "$POLYLINE_LEN" "$STEPS_LEN" <<'PY'
import sys
distance = float(sys.argv[1])
polyline_len = int(sys.argv[2])
steps_len = int(sys.argv[3])
if distance <= 0:
    raise SystemExit(f"expected distance_m > 0, got {distance}")
if polyline_len < 2:
    raise SystemExit(f"expected path_polyline length >= 2, got {polyline_len}")
if steps_len < 2:
    raise SystemExit(f"expected navigation_steps length >= 2, got {steps_len}")
print(f"navigate distance_m={distance}, polyline={polyline_len}, steps={steps_len}")
PY
pass "navigate_between_points returned polyline and steps"

echo "--- HTTP API ---"
HEALTH_CODE="$(curl -s -o /tmp/park-routing-health.json -w "%{http_code}" "$API_BASE/health")"
[[ "$HEALTH_CODE" == "200" ]] || fail "health check returned HTTP $HEALTH_CODE"
pass "GET /health returned 200"

ROUTE_BODY="$(cat <<EOF
{
  "start": { "lon": $START_LON, "lat": $START_LAT },
  "end":   { "lon": $END_LON, "lat": $END_LAT },
  "travel_mode": "walk",
  "crs": "wgs84"
}
EOF
)"

ROUTE_CODE="$(curl -s -o /tmp/park-routing-route.json -w "%{http_code}" \
  -X POST "$API_BASE/api/v1/route" \
  -H 'Content-Type: application/json' \
  -d "$ROUTE_BODY")"
[[ "$ROUTE_CODE" == "200" ]] || fail "POST /api/v1/route returned HTTP $ROUTE_CODE"
python3 - /tmp/park-routing-route.json <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
coords = data.get("geometry", {}).get("coordinates", [])
if len(coords) < 2:
    raise SystemExit(f"expected route geometry with >= 2 points, got {len(coords)}")
if data.get("distance_m", 0) <= 0:
    raise SystemExit("expected distance_m > 0")
print(f"route API distance_m={data['distance_m']}, points={len(coords)}")
PY
pass "POST /api/v1/route returned geometry"

NAV_CODE="$(curl -s -o /tmp/park-routing-navigate.json -w "%{http_code}" \
  -X POST "$API_BASE/api/v1/navigate" \
  -H 'Content-Type: application/json' \
  -d "$ROUTE_BODY")"
[[ "$NAV_CODE" == "200" ]] || fail "POST /api/v1/navigate returned HTTP $NAV_CODE"
python3 - /tmp/park-routing-navigate.json <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
polyline = data.get("path_polyline", [])
steps = data.get("navigation_steps", [])
if len(polyline) < 2:
    raise SystemExit(f"expected path_polyline length >= 2, got {len(polyline)}")
if len(steps) < 2:
    raise SystemExit(f"expected navigation_steps length >= 2, got {len(steps)}")
if data.get("distance_m", 0) <= 0:
    raise SystemExit("expected distance_m > 0")
print(f"navigate API distance_m={data['distance_m']}, polyline={len(polyline)}, steps={len(steps)}")
PY
pass "POST /api/v1/navigate returned polyline and steps"

echo "=== All smoke tests passed ==="
