#!/usr/bin/env python3
"""Generate db/init/03-park-routes-seed.sql from data/park-routes.geojson."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GEOJSON_PATH = ROOT / "data" / "park-routes.geojson"
OUTPUT_PATH = ROOT / "db" / "init" / "03-park-routes-seed.sql"


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> int:
    with GEOJSON_PATH.open(encoding="utf-8") as f:
        collection = json.load(f)

    if collection.get("type") != "FeatureCollection":
        print("Expected FeatureCollection", file=sys.stderr)
        return 1

    features = collection["features"]
    if not features:
        print("No features found", file=sys.stderr)
        return 1

    lines = [
        "-- Auto-generated from data/park-routes.geojson",
        "-- Do not edit by hand. Regenerate with: python3 scripts/generate_park_routes_seed.py",
        "",
        "INSERT INTO park_ways (name, allows_cart, cost, the_geom) VALUES",
    ]

    values: list[str] = []
    for feature in features:
        geometry = feature.get("geometry")
        properties = feature.get("properties") or {}

        if geometry is None or geometry.get("type") != "LineString":
            print(f"Skipping non-LineString feature: {properties}", file=sys.stderr)
            continue

        route_id = properties.get("ID")
        if route_id is None:
            print("Feature missing properties.ID", file=sys.stderr)
            return 1

        name = f"Route {route_id}"
        geom_json = json.dumps(geometry, separators=(",", ":"))
        values.append(
            "(\n"
            f"  {sql_literal(name)},\n"
            "  TRUE,\n"
            f"  ST_Length(ST_SetSRID(ST_GeomFromGeoJSON({sql_literal(geom_json)}), 4326)::geography),\n"
            f"  ST_SetSRID(ST_GeomFromGeoJSON({sql_literal(geom_json)}), 4326)\n"
            ")"
        )

    lines.append(",\n".join(values) + ";")
    lines.append("")

    OUTPUT_PATH.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {len(values)} rows to {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
