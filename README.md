# Park Routing

Park internal road navigation API built with **PostgreSQL + PostGIS + pgRouting** and a **Rust (Axum/Tokio)** service layer with **Redis** caching.

## Architecture

```
Client → Axum API → Redis (cache hit)
                 └→ PostgreSQL/pgRouting (cache miss) → async cache write
```

## Quick start

### 1. Start infrastructure

```bash
docker compose up -d db redis
```

On first run, `db/init/*.sql` (run in order `01`–`07`) creates extensions, schema, park network seed (346 roads from `data/park-road.json`), topology, GCJ-02 conversion functions, `route_between_points()`, and `navigate_between_points()`. This folder is the schema source of truth for new environments.

**Existing database volumes** do not re-run init scripts. After pulling network or schema changes, reset with `docker compose down -v && docker compose up -d db redis`, reload the network with `./scripts/reload_park_network.sh`, or apply individual SQL files manually.

To regenerate the seed after editing `data/park-road.json`:

```bash
python3 scripts/generate_park_road_seed.py
./scripts/reload_park_network.sh   # if the database already exists
```

To reset the database during development:

```bash
docker compose down -v && docker compose up -d db redis
```

### 2. Run the API locally

```bash
cp .env.example .env
cd backend && cargo run
```

The API listens on `http://localhost:8080`.

Interactive API docs (Swagger UI): [http://localhost:8080/swagger-ui/](http://localhost:8080/swagger-ui/)

OpenAPI JSON: [http://localhost:8080/api-docs/openapi.json](http://localhost:8080/api-docs/openapi.json)

### 3. Or run everything in Docker

```bash
docker compose up -d --build
```

## Smoke tests

Run the full suite (database + SQL routing + HTTP API):

```bash
./scripts/smoke_test.sh
```

Requires `db` and `redis` running; for HTTP checks, start the API (`cargo run` or `docker compose up api`).

Verify database extensions:

```bash
docker compose exec db psql -U postgres -d park_routing -c "SELECT pgr_version();"
docker compose exec db psql -U postgres -d park_routing -c "SELECT COUNT(*) FROM park_ways;"
```

Test navigation in SQL (WGS84, real park bbox: lon 113.885–113.890, lat 22.530–22.543):

```bash
docker compose exec db psql -U postgres -d park_routing -c \
  "SELECT distance_m, duration_sec, jsonb_array_length(path_polyline), jsonb_array_length(navigation_steps) FROM navigate_between_points(113.887401, 22.535316, 113.886131, 22.534781, 'walk', 'wgs84');"
```

Test routing in SQL (WGS84):

```bash
docker compose exec db psql -U postgres -d park_routing -c \
  "SELECT distance_m, duration_min FROM route_between_points(113.887401, 22.535316, 113.886131, 22.534781, 'walk', 'wgs84');"
```

Test GCJ-02 conversion:

```bash
docker compose exec db psql -U postgres -d park_routing -c \
  "SELECT * FROM wgs84_lonlat_to_gcj02(116.397128, 39.916527);"
```

Health check:

```bash
curl http://localhost:8080/health
```

Route API (real park bbox: lon 113.885–113.890, lat 22.530–22.543):

```bash
curl -s -X POST http://localhost:8080/api/v1/route \
  -H 'Content-Type: application/json' \
  -d '{
    "start": { "lon": 113.887401, "lat": 22.535316 },
    "end":   { "lon": 113.886131, "lat": 22.534781 },
    "travel_mode": "walk",
    "crs": "wgs84"
  }' | jq .
```

Repeat the same request — `"cached": true` on the second call.

Navigate API (turn-by-turn steps + dense polyline):

```bash
curl -s -X POST http://localhost:8080/api/v1/navigate \
  -H 'Content-Type: application/json' \
  -d '{
    "start": { "lon": 113.887401, "lat": 22.535316 },
    "end":   { "lon": 113.886131, "lat": 22.534781 },
    "travel_mode": "walk",
    "crs": "wgs84"
  }' | jq .
```

Repeat the same request — `"cached": true` on the second call.

## API

### `POST /api/v1/route`

**Request**

```json
{
  "start": { "lon": 113.887401, "lat": 22.535316 },
  "end": { "lon": 113.886131, "lat": 22.534781 },
  "travel_mode": "walk",
  "crs": "gcj02"
}
```

`travel_mode`: `walk` | `cart`

`crs` (required): `gcj02` | `wgs84` — coordinate system for `start`, `end`, and response `geometry`. Use `gcj02` for 高德 map overlays; use `wgs84` for raw GPS. Internal routing and storage always use WGS84 (EPSG:4326).

**Response**

```json
{
  "geometry": { "type": "LineString", "coordinates": [[116.388, 39.988], ...] },
  "distance_m": 842.5,
  "duration_min": 10.0,
  "cached": false
}
```

### `POST /api/v1/navigate`

End-user AR navigation: same request body as `/api/v1/route`, but returns a dense `path_polyline` and turn-by-turn `navigation_steps` instead of GeoJSON.

**Response**

```json
{
  "distance_m": 563.7,
  "duration_sec": 403,
  "path_polyline": [
    { "lat": 39.988, "lon": 116.388 },
    { "lat": 39.99, "lon": 116.39 }
  ],
  "navigation_steps": [
    {
      "step_index": 0,
      "lat": 39.988,
      "lon": 116.388,
      "action_type": "START",
      "guide_text": "从当前位置出发",
      "distance_to_next_m": 222
    },
    {
      "step_index": 1,
      "lat": 39.99,
      "lon": 116.388,
      "action_type": "RIGHT",
      "guide_text": "在此处右转",
      "distance_to_next_m": 342
    },
    {
      "step_index": 2,
      "lat": 39.99,
      "lon": 116.392,
      "action_type": "DESTINATION",
      "guide_text": "到达目的地",
      "distance_to_next_m": 0
    }
  ],
  "cached": false
}
```

`action_type`: `START` | `STRAIGHT` | `LEFT` | `RIGHT` | `DESTINATION`

### `GET /health` — Postgres + Redis connectivity

## Configuration

See [`.env.example`](.env.example).

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | local postgres | PostgreSQL connection string |
| `REDIS_URL` | `redis://localhost:6379` | Redis connection string |
| `LISTEN_ADDR` | `0.0.0.0:8080` | HTTP bind address |
| `CACHE_GRID_PRECISION` | `4` | Decimal places for coordinate grid cache keys |
| `CACHE_TTL_SECONDS` | `600` | Dynamic route cache TTL (10 min) |

## Routing model

Park paths are modeled as an **undirected graph**: each edge has a single `cost` (meters), and `pgr_dijkstra` runs with `directed => false`. Travel-mode restrictions (e.g. cart vs walk) are enforced by filtering edges (`allows_cart`), not by one-way costs.

## Project layout

```
├── docker-compose.yml
├── data/              # Source GeoJSON (park-road.json)
├── db/init/           # PostgreSQL schema + seed (01–07, lexicographic order)
├── scripts/           # Seed generator, network reload, smoke tests
├── backend/           # Rust Axum API
└── PRDs/prd.md        # Product requirements
```
