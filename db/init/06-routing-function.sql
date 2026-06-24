-- Routing API for the Rust service layer (pgRouting 4.x, undirected graph).
-- Input/output coordinates use the caller-specified crs; internal routing is WGS84 only.

CREATE OR REPLACE FUNCTION _park_edge_endpoint_fraction(
    edge_geom GEOMETRY,
    endpoint_geom GEOMETRY
)
RETURNS DOUBLE PRECISION
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN ST_DWithin(ST_StartPoint(edge_geom), endpoint_geom, 1e-8) THEN 0.0
        ELSE 1.0
    END;
$$;

CREATE OR REPLACE FUNCTION _park_edge_subline_between_fractions(
    edge_geom GEOMETRY,
    frac_a DOUBLE PRECISION,
    frac_b DOUBLE PRECISION
)
RETURNS GEOMETRY
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT ST_LineSubstring(
        edge_geom,
        LEAST(frac_a, frac_b),
        GREATEST(frac_a, frac_b)
    );
$$;

CREATE OR REPLACE FUNCTION _park_merge_line_segments(segments GEOMETRY[])
RETURNS GEOMETRY
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    pts GEOMETRY[] := ARRAY[]::GEOMETRY[];
    seg GEOMETRY;
    i INTEGER;
    pt GEOMETRY;
    last_pt GEOMETRY;
BEGIN
    FOREACH seg IN ARRAY segments LOOP
        IF seg IS NULL OR ST_IsEmpty(seg) THEN
            CONTINUE;
        END IF;

        i := 1;
        WHILE i <= ST_NPoints(seg) LOOP
            pt := ST_PointN(seg, i);
            IF last_pt IS NULL OR NOT ST_Equals(pt, last_pt) THEN
                pts := array_append(pts, pt);
                last_pt := pt;
            END IF;
            i := i + 1;
        END LOOP;
    END LOOP;

    IF array_length(pts, 1) IS NULL OR array_length(pts, 1) < 2 THEN
        RETURN NULL;
    END IF;

    RETURN ST_MakeLine(pts);
END;
$$;

CREATE OR REPLACE FUNCTION _park_orient_edge_geom(
    edge_geom GEOMETRY,
    from_vid BIGINT,
    to_vid BIGINT,
    edge_source INTEGER,
    edge_target INTEGER,
    source_geom GEOMETRY,
    target_geom GEOMETRY
)
RETURNS GEOMETRY
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN from_vid = edge_source AND to_vid = edge_target THEN edge_geom
        WHEN from_vid = edge_target AND to_vid = edge_source THEN ST_Reverse(edge_geom)
        WHEN ST_DWithin(ST_StartPoint(edge_geom), source_geom, 1e-8) THEN edge_geom
        ELSE ST_Reverse(edge_geom)
    END;
$$;

CREATE OR REPLACE FUNCTION _park_compute_complete_route_wgs84(
    start_pt GEOMETRY,
    end_pt GEOMETRY,
    edges_sql TEXT,
    max_snap_m DOUBLE PRECISION DEFAULT 50.0
)
RETURNS TABLE (
    route_geom GEOMETRY,
    distance_m DOUBLE PRECISION,
    start_snap GEOMETRY,
    end_snap GEOMETRY,
    start_vid BIGINT,
    end_vid BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  start_edge RECORD;
  end_edge RECORD;
  best_start_vid BIGINT;
  best_end_vid BIGINT;
  best_network_cost DOUBLE PRECISION;
  best_start_partial DOUBLE PRECISION;
  best_end_partial DOUBLE PRECISION;
  candidate_start_vid BIGINT;
  candidate_end_vid BIGINT;
  candidate_network_cost DOUBLE PRECISION;
  candidate_start_partial DOUBLE PRECISION;
  candidate_end_partial DOUBLE PRECISION;
  source_frac DOUBLE PRECISION;
  target_frac DOUBLE PRECISION;
  route_rec RECORD;
  segments GEOMETRY[] := ARRAY[]::GEOMETRY[];
  oriented_geom GEOMETRY;
  first_edge BOOLEAN := TRUE;
  last_edge_id INTEGER;
  prev_to_vid BIGINT;
  start_access GEOMETRY;
  end_access GEOMETRY;
  full_geom GEOMETRY;
  total_distance DOUBLE PRECISION;
BEGIN
  SELECT
    w.id,
    w.source,
    w.target,
    w.cost,
    w.the_geom,
    ST_ClosestPoint(w.the_geom, start_pt) AS snap_geom,
    ST_LineLocatePoint(w.the_geom, ST_ClosestPoint(w.the_geom, start_pt)) AS snap_frac,
    ST_Distance(w.the_geom::geography, start_pt::geography) AS snap_dist_m
  INTO start_edge
  FROM park_ways w
  ORDER BY w.the_geom <-> start_pt
  LIMIT 1;

  SELECT
    w.id,
    w.source,
    w.target,
    w.cost,
    w.the_geom,
    ST_ClosestPoint(w.the_geom, end_pt) AS snap_geom,
    ST_LineLocatePoint(w.the_geom, ST_ClosestPoint(w.the_geom, end_pt)) AS snap_frac,
    ST_Distance(w.the_geom::geography, end_pt::geography) AS snap_dist_m
  INTO end_edge
  FROM park_ways w
  ORDER BY w.the_geom <-> end_pt
  LIMIT 1;

  IF start_edge.snap_dist_m > max_snap_m THEN
    RAISE EXCEPTION 'Start point is %.0f m from nearest path (max %.0f m)', start_edge.snap_dist_m, max_snap_m
      USING ERRCODE = '22023';
  END IF;

  IF end_edge.snap_dist_m > max_snap_m THEN
    RAISE EXCEPTION 'End point is %.0f m from nearest path (max %.0f m)', end_edge.snap_dist_m, max_snap_m
      USING ERRCODE = '22023';
  END IF;

  start_snap := start_edge.snap_geom;
  end_snap := end_edge.snap_geom;

  best_network_cost := NULL;

  FOR candidate_start_vid IN SELECT unnest(ARRAY[start_edge.source::BIGINT, start_edge.target::BIGINT]) LOOP
    source_frac := _park_edge_endpoint_fraction(
      start_edge.the_geom,
      (SELECT geom FROM park_ways_vertices_pgr WHERE id = candidate_start_vid)
    );
    candidate_start_partial := ABS(start_edge.snap_frac - source_frac) * start_edge.cost;

    FOR candidate_end_vid IN SELECT unnest(ARRAY[end_edge.source::BIGINT, end_edge.target::BIGINT]) LOOP
      target_frac := _park_edge_endpoint_fraction(
        end_edge.the_geom,
        (SELECT geom FROM park_ways_vertices_pgr WHERE id = candidate_end_vid)
      );
      candidate_end_partial := ABS(end_edge.snap_frac - target_frac) * end_edge.cost;

      SELECT r.agg_cost
      INTO candidate_network_cost
      FROM pgr_dijkstra(
        edges_sql,
        candidate_start_vid,
        candidate_end_vid,
        directed => FALSE
      ) AS r
      ORDER BY r.seq DESC
      LIMIT 1;

      IF candidate_network_cost IS NULL THEN
        CONTINUE;
      END IF;

      IF best_network_cost IS NULL
         OR (candidate_start_partial + candidate_network_cost + candidate_end_partial) < best_network_cost THEN
        best_network_cost := candidate_start_partial + candidate_network_cost + candidate_end_partial;
        best_start_vid := candidate_start_vid;
        best_end_vid := candidate_end_vid;
        best_start_partial := candidate_start_partial;
        best_end_partial := candidate_end_partial;
      END IF;
    END LOOP;
  END LOOP;

  IF best_network_cost IS NULL THEN
    RAISE EXCEPTION 'No route found between the given points'
      USING ERRCODE = 'P0002';
  END IF;

  start_vid := best_start_vid;
  end_vid := best_end_vid;

  start_access := ST_MakeLine(start_pt, start_snap);
  IF ST_Length(start_access::geography) > 0.01 THEN
    segments := array_append(segments, start_access);
  END IF;

  source_frac := _park_edge_endpoint_fraction(
    start_edge.the_geom,
    (SELECT geom FROM park_ways_vertices_pgr WHERE id = best_start_vid)
  );
  segments := array_append(
    segments,
    _park_edge_subline_between_fractions(start_edge.the_geom, start_edge.snap_frac, source_frac)
  );

  prev_to_vid := best_start_vid;
  last_edge_id := NULL;

  FOR route_rec IN
    SELECT r.seq, r.edge, r.node AS from_vid,
           CASE WHEN r.node = w.source THEN w.target ELSE w.source END AS to_vid,
           w.the_geom, w.source, w.target, w.name
    FROM pgr_dijkstra(
      edges_sql,
      best_start_vid,
      best_end_vid,
      directed => FALSE
    ) AS r
    JOIN park_ways w ON w.id = r.edge
    WHERE r.edge > 0
    ORDER BY r.seq
  LOOP
    last_edge_id := route_rec.edge;

    IF route_rec.edge = start_edge.id AND route_rec.edge = end_edge.id THEN
      segments := segments[1:array_length(segments, 1) - 1];
      segments := array_append(
        segments,
        _park_edge_subline_between_fractions(
          start_edge.the_geom,
          start_edge.snap_frac,
          end_edge.snap_frac
        )
      );
      prev_to_vid := route_rec.to_vid;
      CONTINUE;
    END IF;

    IF route_rec.edge = start_edge.id THEN
      segments := segments[1:array_length(segments, 1) - 1];
      oriented_geom := _park_orient_edge_geom(
        route_rec.the_geom,
        route_rec.from_vid,
        route_rec.to_vid,
        route_rec.source,
        route_rec.target,
        (SELECT geom FROM park_ways_vertices_pgr WHERE id = route_rec.source),
        (SELECT geom FROM park_ways_vertices_pgr WHERE id = route_rec.target)
      );
      target_frac := _park_edge_endpoint_fraction(
        route_rec.the_geom,
        (SELECT geom FROM park_ways_vertices_pgr WHERE id = route_rec.to_vid)
      );
      segments := array_append(
        segments,
        _park_edge_subline_between_fractions(oriented_geom, start_edge.snap_frac, target_frac)
      );
    ELSIF route_rec.edge = end_edge.id THEN
      oriented_geom := _park_orient_edge_geom(
        route_rec.the_geom,
        route_rec.from_vid,
        route_rec.to_vid,
        route_rec.source,
        route_rec.target,
        (SELECT geom FROM park_ways_vertices_pgr WHERE id = route_rec.source),
        (SELECT geom FROM park_ways_vertices_pgr WHERE id = route_rec.target)
      );
      target_frac := _park_edge_endpoint_fraction(
        route_rec.the_geom,
        (SELECT geom FROM park_ways_vertices_pgr WHERE id = route_rec.from_vid)
      );
      segments := array_append(
        segments,
        _park_edge_subline_between_fractions(oriented_geom, target_frac, end_edge.snap_frac)
      );
    ELSE
      oriented_geom := _park_orient_edge_geom(
        route_rec.the_geom,
        route_rec.from_vid,
        route_rec.to_vid,
        route_rec.source,
        route_rec.target,
        (SELECT geom FROM park_ways_vertices_pgr WHERE id = route_rec.source),
        (SELECT geom FROM park_ways_vertices_pgr WHERE id = route_rec.target)
      );
      segments := array_append(segments, oriented_geom);
    END IF;

    prev_to_vid := route_rec.to_vid;
  END LOOP;

  IF last_edge_id IS DISTINCT FROM end_edge.id THEN
    target_frac := _park_edge_endpoint_fraction(
      end_edge.the_geom,
      (SELECT geom FROM park_ways_vertices_pgr WHERE id = best_end_vid)
    );
    segments := array_append(
      segments,
      _park_edge_subline_between_fractions(end_edge.the_geom, target_frac, end_edge.snap_frac)
    );
  END IF;

  end_access := ST_MakeLine(end_snap, end_pt);
  IF ST_Length(end_access::geography) > 0.01 THEN
    segments := array_append(segments, end_access);
  END IF;

  full_geom := _park_merge_line_segments(segments);

  IF full_geom IS NULL OR ST_IsEmpty(full_geom) THEN
    RAISE EXCEPTION 'No route found between the given points'
      USING ERRCODE = 'P0002';
  END IF;

  route_geom := full_geom;
  distance_m := ST_Length(full_geom::geography);

  RETURN NEXT;
END;
$$;

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
    wgs_start_lon DOUBLE PRECISION;
    wgs_start_lat DOUBLE PRECISION;
    wgs_end_lon DOUBLE PRECISION;
    wgs_end_lat DOUBLE PRECISION;
    converted RECORD;
    start_pt GEOMETRY;
    end_pt GEOMETRY;
    route RECORD;
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

    geojson := ST_AsGeoJSON(output_geom);
    distance_m := route.distance_m;
    duration_min := ROUND((route.distance_m / speed_mps / 60.0)::numeric, 1);

    RETURN NEXT;
END;
$$;
