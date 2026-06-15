-- Routing API for the Rust service layer (pgRouting 4.x, undirected graph).
-- Input/output coordinates use the caller-specified crs; internal routing is WGS84 only.
CREATE OR REPLACE FUNCTION route_between_points(
    start_lon DOUBLE PRECISION,
    start_lat DOUBLE PRECISION,
    end_lon DOUBLE PRECISION,
    end_lat DOUBLE PRECISION,
    mode TEXT DEFAULT 'walk',
    crs TEXT DEFAULT 'wgs84'
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
    wgs_start_lon DOUBLE PRECISION;
    wgs_start_lat DOUBLE PRECISION;
    wgs_end_lon DOUBLE PRECISION;
    wgs_end_lat DOUBLE PRECISION;
    converted RECORD;
    start_pt GEOMETRY;
    end_pt GEOMETRY;
    start_dist DOUBLE PRECISION;
    end_dist DOUBLE PRECISION;
    start_vid BIGINT;
    end_vid BIGINT;
    route_cost DOUBLE PRECISION;
    route_geom GEOMETRY;
    output_geom GEOMETRY;
BEGIN
    IF mode NOT IN ('walk', 'cart') THEN
        RAISE EXCEPTION 'Invalid travel_mode: % (expected walk or cart)', mode
            USING ERRCODE = '22023';
    END IF;

    IF crs NOT IN ('gcj02', 'wgs84') THEN
        RAISE EXCEPTION 'Invalid crs: % (expected gcj02 or wgs84)', crs
            USING ERRCODE = '22023';
    END IF;

    IF crs = 'gcj02' THEN
        SELECT * INTO converted FROM gcj02_lonlat_to_wgs84(start_lon, start_lat);
        wgs_start_lon := converted.wgs_lon;
        wgs_start_lat := converted.wgs_lat;

        SELECT * INTO converted FROM gcj02_lonlat_to_wgs84(end_lon, end_lat);
        wgs_end_lon := converted.wgs_lon;
        wgs_end_lat := converted.wgs_lat;
    ELSE
        wgs_start_lon := start_lon;
        wgs_start_lat := start_lat;
        wgs_end_lon := end_lon;
        wgs_end_lat := end_lat;
    END IF;

    start_pt := ST_SetSRID(ST_MakePoint(wgs_start_lon, wgs_start_lat), 4326);
    end_pt := ST_SetSRID(ST_MakePoint(wgs_end_lon, wgs_end_lat), 4326);

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

    IF crs = 'gcj02' THEN
        output_geom := geom_wgs84_to_gcj02(route_geom);
    ELSE
        output_geom := route_geom;
    END IF;

    geojson := ST_AsGeoJSON(output_geom);
    distance_m := route_cost;
    duration_min := ROUND((route_cost / speed_mps / 60.0)::numeric, 1);

    RETURN NEXT;
END;
$$;
