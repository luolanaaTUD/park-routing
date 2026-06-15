-- Turn-by-turn navigation for AR/mobile clients (pgRouting 4.x, undirected graph).
-- Input/output coordinates use the caller-specified crs; internal routing is WGS84 only.

CREATE OR REPLACE FUNCTION navigate_turn_action(turn_deg DOUBLE PRECISION)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN ABS(turn_deg) <= 30 THEN NULL
        WHEN turn_deg > 30 THEN 'RIGHT'
        ELSE 'LEFT'
    END;
$$;

CREATE OR REPLACE FUNCTION navigate_guide_text(action_type TEXT, road_name TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE action_type
        WHEN 'START' THEN
            CASE WHEN road_name IS NOT NULL AND road_name <> ''
                THEN '沿' || road_name || '直行'
                ELSE '沿当前道路直行'
            END
        WHEN 'STRAIGHT' THEN
            CASE WHEN road_name IS NOT NULL AND road_name <> ''
                THEN '继续沿' || road_name || '直行'
                ELSE '继续直行'
            END
        WHEN 'LEFT' THEN
            CASE WHEN road_name IS NOT NULL AND road_name <> ''
                THEN '在' || road_name || '左转'
                ELSE '在此处左转'
            END
        WHEN 'RIGHT' THEN
            CASE WHEN road_name IS NOT NULL AND road_name <> ''
                THEN '在' || road_name || '右转'
                ELSE '在此处右转'
            END
        WHEN 'DESTINATION' THEN '到达目的地'
        ELSE '继续直行'
    END;
$$;

CREATE OR REPLACE FUNCTION navigate_between_points(
    start_lon DOUBLE PRECISION,
    start_lat DOUBLE PRECISION,
    end_lon DOUBLE PRECISION,
    end_lat DOUBLE PRECISION,
    mode TEXT DEFAULT 'walk',
    crs TEXT DEFAULT 'wgs84'
)
RETURNS TABLE (
    distance_m DOUBLE PRECISION,
    duration_sec INTEGER,
    path_polyline JSONB,
    navigation_steps JSONB
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
    nav_result RECORD;
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
        SELECT r.seq, r.edge, r.agg_cost, r.cost
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
            SUM(w.cost) AS total_cost
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

    SELECT *
    INTO nav_result
    FROM (
        WITH route AS (
            SELECT r.seq, r.edge, r.node AS from_vid, r.agg_cost,
                   CASE
                       WHEN r.node = w.source THEN w.target
                       ELSE w.source
                   END AS to_vid
            FROM pgr_dijkstra(
                edges_sql,
                start_vid,
                end_vid,
                directed => FALSE
            ) AS r
            JOIN park_ways w ON w.id = r.edge
            WHERE r.edge > 0
        ),
        oriented AS (
            SELECT
                r.seq,
                r.edge,
                r.from_vid,
                r.to_vid,
                r.agg_cost,
                w.name AS road_name,
                vf.geom AS from_geom,
                vt.geom AS to_geom,
                degrees(ST_Azimuth(vf.geom, vt.geom)) AS bearing_deg
            FROM route r
            JOIN park_ways w ON w.id = r.edge
            JOIN park_ways_vertices_pgr vf ON vf.id = r.from_vid
            JOIN park_ways_vertices_pgr vt ON vt.id = r.to_vid
        ),
        turns AS (
            SELECT
                o2.seq AS after_seq,
                o2.from_vid AS junction_vid,
                o2.from_geom AS junction_geom,
                o2.agg_cost AS cost_at_junction,
                navigate_turn_action(
                    ((o2.bearing_deg - o1.bearing_deg + 540)::numeric % 360)::double precision - 180
                ) AS action_type,
                o2.road_name
            FROM oriented o1
            JOIN oriented o2 ON o2.seq = o1.seq + 1
            WHERE o1.to_vid = o2.from_vid
        ),
        turn_steps AS (
            SELECT
                t.after_seq,
                t.cost_at_junction,
                t.action_type,
                CASE
                    WHEN crs = 'gcj02' THEN geom_wgs84_to_gcj02(t.junction_geom)
                    ELSE t.junction_geom
                END AS step_geom,
                t.road_name
            FROM turns t
            WHERE t.action_type IS NOT NULL
        ),
        first_edge AS (
            SELECT o.edge, o.road_name, w.the_geom
            FROM oriented o
            JOIN park_ways w ON w.id = o.edge
            ORDER BY o.seq
            LIMIT 1
        ),
        last_edge AS (
            SELECT o.edge, w.the_geom
            FROM oriented o
            JOIN park_ways w ON w.id = o.edge
            ORDER BY o.seq DESC
            LIMIT 1
        ),
        start_snap AS (
            SELECT CASE
                WHEN crs = 'gcj02' THEN geom_wgs84_to_gcj02(ST_ClosestPoint(fe.the_geom, start_pt))
                ELSE ST_ClosestPoint(fe.the_geom, start_pt)
            END AS geom,
            fe.road_name
            FROM first_edge fe
        ),
        end_snap AS (
            SELECT CASE
                WHEN crs = 'gcj02' THEN geom_wgs84_to_gcj02(ST_ClosestPoint(le.the_geom, end_pt))
                ELSE ST_ClosestPoint(le.the_geom, end_pt)
            END AS geom
            FROM last_edge le
        ),
        raw_steps AS (
            SELECT
                0 AS ord,
                0::BIGINT AS route_seq,
                0::DOUBLE PRECISION AS cost_at_step,
                'START'::TEXT AS action_type,
                s.geom AS step_geom,
                s.road_name
            FROM start_snap s

            UNION ALL

            SELECT
                ts.after_seq AS ord,
                ts.after_seq AS route_seq,
                ts.cost_at_junction AS cost_at_step,
                ts.action_type,
                ts.step_geom,
                ts.road_name
            FROM turn_steps ts

            UNION ALL

            SELECT
                1000000 AS ord,
                1000000::BIGINT AS route_seq,
                route_cost AS cost_at_step,
                'DESTINATION'::TEXT AS action_type,
                e.geom AS step_geom,
                NULL::TEXT AS road_name
            FROM end_snap e
        ),
        ordered_steps AS (
            SELECT
                ROW_NUMBER() OVER (ORDER BY rs.ord, rs.route_seq) - 1 AS step_index,
                rs.action_type,
                rs.step_geom,
                rs.road_name,
                rs.cost_at_step,
                LEAD(rs.cost_at_step) OVER (ORDER BY rs.ord, rs.route_seq) AS next_cost_at_step
            FROM raw_steps rs
        ),
        steps_json AS (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'step_index', os.step_index,
                        'lat', ST_Y(os.step_geom),
                        'lon', ST_X(os.step_geom),
                        'action_type', os.action_type,
                        'guide_text', navigate_guide_text(os.action_type, os.road_name),
                        'distance_to_next_m', GREATEST(
                            0,
                            ROUND(
                                COALESCE(os.next_cost_at_step, os.cost_at_step) - os.cost_at_step
                            )::INTEGER
                        )
                    )
                    ORDER BY os.step_index
                ),
                '[]'::jsonb
            ) AS steps
            FROM ordered_steps os
        ),
        polyline_pts AS (
            SELECT
                GREATEST(2, CEIL(ST_Length(output_geom::geography) / 5.0))::INTEGER AS n_pts
        ),
        polyline_json AS (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object('lat', ST_Y(pt), 'lon', ST_X(pt))
                    ORDER BY i
                ),
                '[]'::jsonb
            ) AS polyline
            FROM polyline_pts p
            CROSS JOIN LATERAL generate_series(0, p.n_pts - 1) AS i
            CROSS JOIN LATERAL ST_LineInterpolatePoint(
                output_geom,
                CASE
                    WHEN p.n_pts <= 1 THEN 0::DOUBLE PRECISION
                    ELSE i::DOUBLE PRECISION / (p.n_pts - 1)
                END
            ) AS pt
        )
        SELECT
            route_cost AS distance_m,
            GREATEST(1, ROUND(route_cost / speed_mps)::INTEGER) AS duration_sec,
            pj.polyline AS path_polyline,
            sj.steps AS navigation_steps
        FROM polyline_json pj, steps_json sj
    ) nav;

    distance_m := nav_result.distance_m;
    duration_sec := nav_result.duration_sec;
    path_polyline := nav_result.path_polyline;
    navigation_steps := nav_result.navigation_steps;

    RETURN NEXT;
END;
$$;
