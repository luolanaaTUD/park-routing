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
        WHEN 'START' THEN '从当前位置出发'
        WHEN 'STRAIGHT' THEN '继续直行'
        WHEN 'LEFT' THEN '在此处左转'
        WHEN 'RIGHT' THEN '在此处右转'
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
    wgs_start_lon DOUBLE PRECISION;
    wgs_start_lat DOUBLE PRECISION;
    wgs_end_lon DOUBLE PRECISION;
    wgs_end_lat DOUBLE PRECISION;
    converted RECORD;
    start_pt GEOMETRY;
    end_pt GEOMETRY;
    route RECORD;
    output_geom GEOMETRY;
    start_access_m DOUBLE PRECISION;
    end_access_m DOUBLE PRECISION;
    first_road_name TEXT;
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

    IF mode = 'walk' THEN
        edges_sql := 'SELECT id, source, target, cost FROM park_ways ORDER BY id';
        speed_mps := 1.4;
    ELSE
        edges_sql := 'SELECT id, source, target, cost FROM park_ways WHERE allows_cart = true ORDER BY id';
        speed_mps := 3.0;
    END IF;

    SELECT *
    INTO route
    FROM _park_compute_complete_route_wgs84(start_pt, end_pt, edges_sql);

    IF crs = 'gcj02' THEN
        output_geom := geom_wgs84_to_gcj02(route.route_geom);
    ELSE
        output_geom := route.route_geom;
    END IF;

    start_access_m := ST_Distance(start_pt::geography, route.start_snap::geography);
    end_access_m := ST_Distance(route.end_snap::geography, end_pt::geography);

    SELECT w.name
    INTO first_road_name
    FROM park_ways w
    ORDER BY w.the_geom <-> route.start_snap
    LIMIT 1;

    SELECT *
    INTO nav_result
    FROM (
        WITH route_edges AS (
            SELECT r.seq, r.edge, r.node AS from_vid, r.agg_cost,
                   CASE
                       WHEN r.node = w.source THEN w.target
                       ELSE w.source
                   END AS to_vid
            FROM pgr_dijkstra(
                edges_sql,
                route.start_vid,
                route.end_vid,
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
                oriented_geom.edge_geom,
                degrees(ST_Azimuth(
                    ST_LineInterpolatePoint(
                        oriented_geom.edge_geom,
                        GREATEST(
                            0::DOUBLE PRECISION,
                            1.0 - 5.0 / NULLIF(ST_Length(oriented_geom.edge_geom::geography), 0)
                        )
                    ),
                    ST_EndPoint(oriented_geom.edge_geom)
                )) AS arrive_bearing_deg,
                degrees(ST_Azimuth(
                    ST_StartPoint(oriented_geom.edge_geom),
                    ST_LineInterpolatePoint(
                        oriented_geom.edge_geom,
                        LEAST(
                            1::DOUBLE PRECISION,
                            5.0 / NULLIF(ST_Length(oriented_geom.edge_geom::geography), 0)
                        )
                    )
                )) AS depart_bearing_deg
            FROM route_edges r
            JOIN park_ways w ON w.id = r.edge
            JOIN park_ways_vertices_pgr vf ON vf.id = r.from_vid
            JOIN park_ways_vertices_pgr vt ON vt.id = r.to_vid
            CROSS JOIN LATERAL (
                SELECT _park_orient_edge_geom(
                    w.the_geom, r.from_vid, r.to_vid, w.source, w.target, vf.geom, vt.geom
                ) AS edge_geom
            ) AS oriented_geom
        ),
        turns AS (
            SELECT
                o2.seq AS after_seq,
                o2.from_vid AS junction_vid,
                o2.from_geom AS junction_geom,
                o2.agg_cost AS cost_at_junction,
                navigate_turn_action(
                    ((o2.depart_bearing_deg - o1.arrive_bearing_deg + 540)::numeric % 360)::double precision - 180
                ) AS action_type,
                o2.road_name
            FROM oriented o1
            JOIN oriented o2 ON o2.seq = o1.seq + 1
            WHERE o1.to_vid = o2.from_vid
        ),
        turn_steps AS (
            SELECT
                ts.after_seq,
                ts.cost_at_junction,
                ts.action_type,
                CASE
                    WHEN crs = 'gcj02' THEN geom_wgs84_to_gcj02(ts.junction_geom)
                    ELSE ts.junction_geom
                END AS step_geom,
                ts.road_name
            FROM turns ts
            WHERE ts.action_type IS NOT NULL
        ),
        start_step AS (
            SELECT CASE
                WHEN crs = 'gcj02' THEN geom_wgs84_to_gcj02(start_pt)
                ELSE start_pt
            END AS geom
        ),
        start_snap_step AS (
            SELECT CASE
                WHEN crs = 'gcj02' THEN geom_wgs84_to_gcj02(route.start_snap)
                ELSE route.start_snap
            END AS geom
        ),
        end_snap_step AS (
            SELECT CASE
                WHEN crs = 'gcj02' THEN geom_wgs84_to_gcj02(route.end_snap)
                ELSE route.end_snap
            END AS geom
        ),
        end_step AS (
            SELECT CASE
                WHEN crs = 'gcj02' THEN geom_wgs84_to_gcj02(end_pt)
                ELSE end_pt
            END AS geom
        ),
        raw_steps AS (
            SELECT
                0 AS ord,
                0::BIGINT AS route_seq,
                0::DOUBLE PRECISION AS cost_at_step,
                'START'::TEXT AS action_type,
                s.geom AS step_geom,
                NULL::TEXT AS road_name
            FROM start_step s

            UNION ALL

            SELECT
                1 AS ord,
                0::BIGINT AS route_seq,
                start_access_m AS cost_at_step,
                'STRAIGHT'::TEXT AS action_type,
                ss.geom AS step_geom,
                first_road_name AS road_name
            FROM start_snap_step ss
            WHERE start_access_m > 1.0

            UNION ALL

            SELECT
                ts.after_seq + 10 AS ord,
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
                route.distance_m - end_access_m AS cost_at_step,
                'STRAIGHT'::TEXT AS action_type,
                es.geom AS step_geom,
                NULL::TEXT AS road_name
            FROM end_snap_step es
            WHERE end_access_m > 1.0

            UNION ALL

            SELECT
                1000001 AS ord,
                1000001::BIGINT AS route_seq,
                route.distance_m AS cost_at_step,
                'DESTINATION'::TEXT AS action_type,
                e.geom AS step_geom,
                NULL::TEXT AS road_name
            FROM end_step e
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
            route.distance_m AS distance_m,
            GREATEST(1, ROUND(route.distance_m / speed_mps)::INTEGER) AS duration_sec,
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
