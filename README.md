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

On first run, `db/init/*.sql` (run in order `01`–`05`) creates extensions, schema, sample network, topology, and `route_between_points()`. This folder is the schema source of truth for new environments.

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

Verify database extensions:

```bash
docker compose exec db psql -U postgres -d park_routing -c "SELECT pgr_version();"
docker compose exec db psql -U postgres -d park_routing -c "SELECT COUNT(*) FROM park_ways;"
```

Test routing in SQL:

```bash
docker compose exec db psql -U postgres -d park_routing -c \
  "SELECT distance_m, duration_min FROM route_between_points(116.388, 39.988, 116.392, 39.992, 'walk');"
```

Health check:

```bash
curl http://localhost:8080/health
```

Route API (synthetic park bbox: lon 116.388–116.392, lat 39.988–39.992):

```bash
curl -s -X POST http://localhost:8080/api/v1/route \
  -H 'Content-Type: application/json' \
  -d '{
    "start": { "lon": 116.388, "lat": 39.988 },
    "end":   { "lon": 116.392, "lat": 39.992 },
    "travel_mode": "walk"
  }' | jq .
```

Repeat the same request — `"cached": true` on the second call.

## API

### `POST /api/v1/route`

**Request**

```json
{
  "start": { "lon": 116.388, "lat": 39.988 },
  "end": { "lon": 116.392, "lat": 39.992 },
  "travel_mode": "walk"
}
```

`travel_mode`: `walk` | `cart`

**Response**

```json
{
  "geometry": { "type": "LineString", "coordinates": [[116.388, 39.988], ...] },
  "distance_m": 842.5,
  "duration_min": 10.0,
  "cached": false
}
```

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
├── db/init/           # PostgreSQL schema + seed (01–05, lexicographic order)
├── backend/           # Rust Axum API
└── PRDs/prd.md        # Product requirements
```
