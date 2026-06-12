-- Routing API for the Rust service layer (pgRouting 4.x, undirected graph).
CREATE OR REPLACE FUNCTION route_between_points(
    start_lon DOUBLE PRECISION,
    start_lat DOUBLE PRECISION,
    end_lon DOUBLE PRECISION,
    end_lat DOUBLE PRECISION,
    mode TEXT DEFAULT 'walk'
)
RETURNS TABLE (
    geojson TEXT,
    distance_m DOUBLE PRECISION,
    duration_min DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    edges_sql TEXT;
    speed_mps DOUBLE PRECISION;
    max_snap_m DOUBLE PRECISION := 50.0;
    start_pt GEOMETRY;
    end_pt GEOMETRY;
    start_dist DOUBLE PRECISION;
    end_dist DOUBLE PRECISION;
    start_vid BIGINT;
    end_vid BIGINT;
    route_cost DOUBLE PRECISION;
    route_geom GEOMETRY;
BEGIN
    IF mode NOT IN ('walk', 'cart') THEN
        RAISE EXCEPTION 'Invalid travel_mode: % (expected walk or cart)', mode
            USING ERRCODE = '22023';
    END IF;

    start_pt := ST_SetSRID(ST_MakePoint(start_lon, start_lat), 4326);
    end_pt := ST_SetSRID(ST_MakePoint(end_lon, end_lat), 4326);

    SELECT MIN(ST_Distance(w.the_geom::geography, start_pt::geography))
    INTO start_dist
    FROM park_ways w;

    SELECT MIN(ST_Distance(w.the_geom::geography, end_pt::geography))
    INTO end_dist
    FROM park_ways w;

    IF start_dist > max_snap_m THEN
        RAISE EXCEPTION 'Start point is %.0f m from nearest path (max %.0f m)', start_dist, max_snap_m
            USING ERRCODE = '22023';
    END IF;

    IF end_dist > max_snap_m THEN
        RAISE EXCEPTION 'End point is %.0f m from nearest path (max %.0f m)', end_dist, max_snap_m
            USING ERRCODE = '22023';
    END IF;

    IF mode = 'walk' THEN
        edges_sql := 'SELECT id, source, target, cost FROM park_ways ORDER BY id';
        speed_mps := 1.4;
    ELSE
        edges_sql := 'SELECT id, source, target, cost FROM park_ways WHERE allows_cart = true ORDER BY id';
        speed_mps := 3.0;
    END IF;

    SELECT v.id
    INTO start_vid
    FROM park_ways_vertices_pgr v
    ORDER BY v.geom <-> start_pt
    LIMIT 1;

    SELECT v.id
    INTO end_vid
    FROM park_ways_vertices_pgr v
    ORDER BY v.geom <-> end_pt
    LIMIT 1;

    WITH route AS (
        SELECT r.seq, r.edge, r.agg_cost
        FROM pgr_dijkstra(
            edges_sql,
            start_vid,
            end_vid,
            directed => FALSE
        ) AS r
        WHERE r.edge > 0
    ),
    aggregated AS (
        SELECT
            ST_LineMerge(ST_Collect(w.the_geom ORDER BY r.seq)) AS geom,
            MAX(r.agg_cost) AS total_cost
        FROM route r
        JOIN park_ways w ON w.id = r.edge
    )
    SELECT a.geom, a.total_cost
    INTO route_geom, route_cost
    FROM aggregated a;

    IF route_geom IS NULL OR route_cost IS NULL THEN
        RAISE EXCEPTION 'No route found between the given points'
            USING ERRCODE = 'P0002';
    END IF;

    geojson := ST_AsGeoJSON(route_geom);
    distance_m := route_cost;
    duration_min := ROUND((route_cost / speed_mps / 60.0)::numeric, 1);

    RETURN NEXT;
END;
$$;
