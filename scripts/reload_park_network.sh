#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Truncating park_ways and rebuilding topology from real park routes seed..."

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d park_routing <<'SQL'
TRUNCATE park_ways RESTART IDENTITY;
ALTER TABLE park_ways ALTER COLUMN source DROP NOT NULL;
ALTER TABLE park_ways ALTER COLUMN target DROP NOT NULL;
SQL

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d park_routing \
  -f /docker-entrypoint-initdb.d/03-park-routes-seed.sql

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d park_routing \
  -f /docker-entrypoint-initdb.d/04-topology.sql

echo "Reload complete. park_ways count:"
docker compose exec -T db psql -U postgres -d park_routing \
  -c "SELECT COUNT(*) FROM park_ways;"
