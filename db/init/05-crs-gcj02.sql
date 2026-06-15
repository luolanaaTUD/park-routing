-- WGS84 (EPSG:4326) <-> GCJ-02 (高德/国内地图) conversion.
-- Internal storage and routing remain WGS84; use these at API boundaries.

CREATE OR REPLACE FUNCTION _gcj02_out_of_china(
    lon DOUBLE PRECISION,
    lat DOUBLE PRECISION
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT lon < 72.004 OR lon > 137.8347 OR lat < 0.8293 OR lat > 55.8271;
$$;

CREATE OR REPLACE FUNCTION _gcj02_transform_lat(
    lon DOUBLE PRECISION,
    lat DOUBLE PRECISION
)
RETURNS DOUBLE PRECISION
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT
        -100.0
        + 2.0 * lon
        + 3.0 * lat
        + 0.2 * lat * lat
        + 0.1 * lon * lat
        + 0.2 * sqrt(abs(lon))
        + (20.0 * sin(6.0 * lon * pi()) + 20.0 * sin(2.0 * lon * pi())) * 2.0 / 3.0
        + (20.0 * sin(lat * pi()) + 40.0 * sin(lat / 3.0 * pi())) * 2.0 / 3.0
        + (160.0 * sin(lat / 12.0 * pi()) + 320.0 * sin(lat * pi() / 30.0)) * 2.0 / 3.0;
$$;

CREATE OR REPLACE FUNCTION _gcj02_transform_lon(
    lon DOUBLE PRECISION,
    lat DOUBLE PRECISION
)
RETURNS DOUBLE PRECISION
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT
        300.0
        + lon
        + 2.0 * lat
        + 0.1 * lon * lon
        + 0.1 * lon * lat
        + 0.1 * sqrt(abs(lon))
        + (20.0 * sin(6.0 * lon * pi()) + 20.0 * sin(2.0 * lon * pi())) * 2.0 / 3.0
        + (20.0 * sin(lon * pi()) + 40.0 * sin(lon / 3.0 * pi())) * 2.0 / 3.0
        + (150.0 * sin(lon / 12.0 * pi()) + 300.0 * sin(lon / 30.0 * pi())) * 2.0 / 3.0;
$$;

CREATE OR REPLACE FUNCTION wgs84_lonlat_to_gcj02(
    wgs_lon DOUBLE PRECISION,
    wgs_lat DOUBLE PRECISION
)
RETURNS TABLE (gcj_lon DOUBLE PRECISION, gcj_lat DOUBLE PRECISION)
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    a CONSTANT DOUBLE PRECISION := 6378245.0;
    ee CONSTANT DOUBLE PRECISION := 0.00669342162296594323;
    d_lon DOUBLE PRECISION;
    d_lat DOUBLE PRECISION;
    rad_lat DOUBLE PRECISION;
    magic DOUBLE PRECISION;
    sqrt_magic DOUBLE PRECISION;
BEGIN
    IF _gcj02_out_of_china(wgs_lon, wgs_lat) THEN
        gcj_lon := wgs_lon;
        gcj_lat := wgs_lat;
        RETURN NEXT;
        RETURN;
    END IF;

    d_lat := _gcj02_transform_lat(wgs_lon - 105.0, wgs_lat - 35.0);
    d_lon := _gcj02_transform_lon(wgs_lon - 105.0, wgs_lat - 35.0);
    rad_lat := radians(wgs_lat);
    magic := sin(rad_lat);
    magic := 1.0 - ee * magic * magic;
    sqrt_magic := sqrt(magic);
    d_lat := (d_lat * 180.0) / (((a * (1.0 - ee)) / (magic * sqrt_magic)) * pi());
    d_lon := (d_lon * 180.0) / ((a / sqrt_magic) * cos(rad_lat) * pi());

    gcj_lon := wgs_lon + d_lon;
    gcj_lat := wgs_lat + d_lat;
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION gcj02_lonlat_to_wgs84(
    gcj_lon DOUBLE PRECISION,
    gcj_lat DOUBLE PRECISION
)
RETURNS TABLE (wgs_lon DOUBLE PRECISION, wgs_lat DOUBLE PRECISION)
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    approx_lon DOUBLE PRECISION;
    approx_lat DOUBLE PRECISION;
    mapped RECORD;
    i INTEGER;
BEGIN
    IF _gcj02_out_of_china(gcj_lon, gcj_lat) THEN
        wgs_lon := gcj_lon;
        wgs_lat := gcj_lat;
        RETURN NEXT;
        RETURN;
    END IF;

    approx_lon := gcj_lon;
    approx_lat := gcj_lat;

    FOR i IN 1..3 LOOP
        SELECT m.gcj_lon, m.gcj_lat
        INTO mapped
        FROM wgs84_lonlat_to_gcj02(approx_lon, approx_lat) AS m;

        approx_lon := approx_lon - (mapped.gcj_lon - gcj_lon);
        approx_lat := approx_lat - (mapped.gcj_lat - gcj_lat);
    END LOOP;

    wgs_lon := approx_lon;
    wgs_lat := approx_lat;
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION _gcj02_point_to_wgs84(p geometry)
RETURNS geometry
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    converted RECORD;
BEGIN
    IF ST_GeometryType(p) <> 'ST_Point' THEN
        RAISE EXCEPTION 'Expected ST_Point, got %', ST_GeometryType(p);
    END IF;

    SELECT *
    INTO converted
    FROM gcj02_lonlat_to_wgs84(ST_X(p), ST_Y(p));

    RETURN ST_SetSRID(ST_MakePoint(converted.wgs_lon, converted.wgs_lat), 4326);
END;
$$;

CREATE OR REPLACE FUNCTION _wgs84_point_to_gcj02(p geometry)
RETURNS geometry
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    converted RECORD;
BEGIN
    IF ST_GeometryType(p) <> 'ST_Point' THEN
        RAISE EXCEPTION 'Expected ST_Point, got %', ST_GeometryType(p);
    END IF;

    SELECT *
    INTO converted
    FROM wgs84_lonlat_to_gcj02(ST_X(p), ST_Y(p));

    RETURN ST_SetSRID(ST_MakePoint(converted.gcj_lon, converted.gcj_lat), 4326);
END;
$$;

CREATE OR REPLACE FUNCTION _gcj02_transform_linestring(g geometry, to_gcj BOOLEAN)
RETURNS geometry
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    points geometry[] := ARRAY[]::geometry[];
    i INTEGER;
BEGIN
    FOR i IN 1..ST_NPoints(g) LOOP
        IF to_gcj THEN
            points := array_append(points, _wgs84_point_to_gcj02(ST_PointN(g, i)));
        ELSE
            points := array_append(points, _gcj02_point_to_wgs84(ST_PointN(g, i)));
        END IF;
    END LOOP;

    RETURN ST_SetSRID(ST_MakeLine(points), 4326);
END;
$$;

CREATE OR REPLACE FUNCTION geom_gcj02_to_wgs84(g geometry)
RETURNS geometry
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    gtype TEXT;
    parts geometry[] := ARRAY[]::geometry[];
    i INTEGER;
    n INTEGER;
    interior_rings geometry[];
    ring geometry;
BEGIN
    IF g IS NULL THEN
        RETURN NULL;
    END IF;

    gtype := ST_GeometryType(g);

    CASE gtype
        WHEN 'ST_Point' THEN
            RETURN _gcj02_point_to_wgs84(g);
        WHEN 'ST_LineString' THEN
            RETURN _gcj02_transform_linestring(g, FALSE);
        WHEN 'ST_Polygon' THEN
            interior_rings := ARRAY[]::geometry[];
            ring := _gcj02_transform_linestring(ST_ExteriorRing(g), FALSE);
            FOR i IN 1..ST_NumInteriorRings(g) LOOP
                interior_rings := array_append(
                    interior_rings,
                    _gcj02_transform_linestring(ST_InteriorRingN(g, i), FALSE)
                );
            END LOOP;
            RETURN ST_SetSRID(ST_MakePolygon(ring, interior_rings), 4326);
        WHEN 'ST_MultiPoint', 'ST_MultiLineString', 'ST_MultiPolygon' THEN
            n := ST_NumGeometries(g);
            FOR i IN 1..n LOOP
                parts := array_append(parts, geom_gcj02_to_wgs84(ST_GeometryN(g, i)));
            END LOOP;
            RETURN ST_SetSRID(ST_Multi(ST_Collect(parts)), 4326);
        WHEN 'ST_GeometryCollection' THEN
            n := ST_NumGeometries(g);
            FOR i IN 1..n LOOP
                parts := array_append(parts, geom_gcj02_to_wgs84(ST_GeometryN(g, i)));
            END LOOP;
            RETURN ST_SetSRID(ST_Collect(parts), 4326);
        ELSE
            RAISE EXCEPTION 'Unsupported geometry type for GCJ-02 conversion: %', gtype;
    END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION geom_wgs84_to_gcj02(g geometry)
RETURNS geometry
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    gtype TEXT;
    parts geometry[] := ARRAY[]::geometry[];
    i INTEGER;
    n INTEGER;
    interior_rings geometry[];
    ring geometry;
BEGIN
    IF g IS NULL THEN
        RETURN NULL;
    END IF;

    gtype := ST_GeometryType(g);

    CASE gtype
        WHEN 'ST_Point' THEN
            RETURN _wgs84_point_to_gcj02(g);
        WHEN 'ST_LineString' THEN
            RETURN _gcj02_transform_linestring(g, TRUE);
        WHEN 'ST_Polygon' THEN
            interior_rings := ARRAY[]::geometry[];
            ring := _gcj02_transform_linestring(ST_ExteriorRing(g), TRUE);
            FOR i IN 1..ST_NumInteriorRings(g) LOOP
                interior_rings := array_append(
                    interior_rings,
                    _gcj02_transform_linestring(ST_InteriorRingN(g, i), TRUE)
                );
            END LOOP;
            RETURN ST_SetSRID(ST_MakePolygon(ring, interior_rings), 4326);
        WHEN 'ST_MultiPoint', 'ST_MultiLineString', 'ST_MultiPolygon' THEN
            n := ST_NumGeometries(g);
            FOR i IN 1..n LOOP
                parts := array_append(parts, geom_wgs84_to_gcj02(ST_GeometryN(g, i)));
            END LOOP;
            RETURN ST_SetSRID(ST_Multi(ST_Collect(parts)), 4326);
        WHEN 'ST_GeometryCollection' THEN
            n := ST_NumGeometries(g);
            FOR i IN 1..n LOOP
                parts := array_append(parts, geom_wgs84_to_gcj02(ST_GeometryN(g, i)));
            END LOOP;
            RETURN ST_SetSRID(ST_Collect(parts), 4326);
        ELSE
            RAISE EXCEPTION 'Unsupported geometry type for GCJ-02 conversion: %', gtype;
    END CASE;
END;
$$;

-- Smoke assertions (idempotent on init)
DO $$
DECLARE
    wgs_lon DOUBLE PRECISION := 116.397128;
    wgs_lat DOUBLE PRECISION := 39.916527;
    gcj RECORD;
    roundtrip RECORD;
    dist_m DOUBLE PRECISION;
    outside RECORD;
    line_wgs geometry;
    line_gcj geometry;
    poly_wgs geometry;
    poly_gcj geometry;
BEGIN
    SELECT * INTO gcj FROM wgs84_lonlat_to_gcj02(wgs_lon, wgs_lat);
    SELECT * INTO roundtrip FROM gcj02_lonlat_to_wgs84(gcj.gcj_lon, gcj.gcj_lat);

    dist_m := ST_Distance(
        ST_SetSRID(ST_MakePoint(wgs_lon, wgs_lat), 4326)::geography,
        ST_SetSRID(ST_MakePoint(roundtrip.wgs_lon, roundtrip.wgs_lat), 4326)::geography
    );
    IF dist_m > 1.0 THEN
        RAISE EXCEPTION 'GCJ-02 round-trip error %.3f m (expected < 1 m)', dist_m;
    END IF;

    SELECT * INTO outside FROM wgs84_lonlat_to_gcj02(2.0, 48.0);
    IF outside.gcj_lon <> 2.0 OR outside.gcj_lat <> 48.0 THEN
        RAISE EXCEPTION 'Outside-China point should be unchanged';
    END IF;

    line_wgs := ST_GeomFromText('LINESTRING(116.388 39.988, 116.392 39.992)', 4326);
    line_gcj := geom_wgs84_to_gcj02(line_wgs);
    IF ST_Equals(line_wgs, line_gcj) THEN
        RAISE EXCEPTION 'LineString GCJ conversion should change coordinates inside China';
    END IF;

    poly_wgs := ST_GeomFromText(
        'POLYGON((116.388 39.988, 116.392 39.988, 116.392 39.992, 116.388 39.992, 116.388 39.988))',
        4326
    );
    poly_gcj := geom_wgs84_to_gcj02(poly_wgs);
    IF ST_Equals(poly_wgs, poly_gcj) THEN
        RAISE EXCEPTION 'Polygon GCJ conversion should change coordinates inside China';
    END IF;
END $$;
