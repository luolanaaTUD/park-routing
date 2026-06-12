-- Core routing tables (PRD §6.1, undirected graph).
-- source/target are populated by 04-topology.sql after edges are loaded.

CREATE TABLE park_ways (
    id           SERIAL PRIMARY KEY,
    source       INTEGER,
    target       INTEGER,
    cost         DOUBLE PRECISION NOT NULL CHECK (cost >= 0),
    allows_cart  BOOLEAN NOT NULL DEFAULT TRUE,
    name         TEXT,
    the_geom     GEOMETRY(LineString, 4326) NOT NULL
);

CREATE INDEX park_ways_source_idx ON park_ways (source);
CREATE INDEX park_ways_target_idx ON park_ways (target);
CREATE INDEX park_ways_geom_idx ON park_ways USING GIST (the_geom);

CREATE TABLE pois (
    id       SERIAL PRIMARY KEY,
    name     TEXT NOT NULL UNIQUE,
    category TEXT,
    the_geom GEOMETRY(Point, 4326) NOT NULL
);

CREATE INDEX pois_geom_idx ON pois USING GIST (the_geom);

CREATE TABLE recommended_routes (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    travel_mode TEXT NOT NULL DEFAULT 'walk' CHECK (travel_mode IN ('walk', 'cart')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
