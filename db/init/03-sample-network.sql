-- Dev seed data: synthetic park network (~1 km²) near 116.390, 39.990.
-- Replace or extend for production parks; cost is edge length in meters.
-- Three horizontal main paths + vertical connectors; one pedestrian-only spine.

INSERT INTO park_ways (name, allows_cart, cost, the_geom) VALUES
-- South main path (cart allowed)
('South Loop', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.388 39.988, 116.392 39.988)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.388 39.988, 116.392 39.988)', 4326)),

-- Central main path
('Central Avenue', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.388 39.990, 116.392 39.990)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.388 39.990, 116.392 39.990)', 4326)),

-- North main path
('North Loop', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.388 39.992, 116.392 39.992)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.388 39.992, 116.392 39.992)', 4326)),

-- West boundary path
('West Trail', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.388 39.988, 116.388 39.992)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.388 39.988, 116.388 39.992)', 4326)),

-- East boundary path
('East Trail', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.392 39.988, 116.392 39.992)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.392 39.988, 116.392 39.992)', 4326)),

-- Pedestrian-only central spine (no cart access)
('Garden Walk', FALSE,
 ST_Length(ST_GeomFromText('LINESTRING(116.390 39.988, 116.390 39.992)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.390 39.988, 116.390 39.992)', 4326)),

-- Connectors: south to central
('S-C West', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.388 39.988, 116.388 39.990)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.388 39.988, 116.388 39.990)', 4326)),

('S-C Center', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.390 39.988, 116.390 39.990)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.390 39.988, 116.390 39.990)', 4326)),

('S-C East', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.392 39.988, 116.392 39.990)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.392 39.988, 116.392 39.990)', 4326)),

-- Connectors: central to north
('C-N West', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.388 39.990, 116.388 39.992)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.388 39.990, 116.388 39.992)', 4326)),

('C-N Center', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.390 39.990, 116.390 39.992)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.390 39.990, 116.390 39.992)', 4326)),

('C-N East', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.392 39.990, 116.392 39.992)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.392 39.990, 116.392 39.992)', 4326)),

-- Diagonal scenic shortcuts (walk-friendly, cart on some)
('Scenic SW', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.388 39.988, 116.390 39.990)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.388 39.988, 116.390 39.990)', 4326)),

('Scenic NE', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.390 39.990, 116.392 39.992)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.390 39.990, 116.392 39.992)', 4326)),

-- Mid-park cross links
('Cross 389', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.389 39.989, 116.389 39.991)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.389 39.989, 116.389 39.991)', 4326)),

('Cross 391', TRUE,
 ST_Length(ST_GeomFromText('LINESTRING(116.391 39.989, 116.391 39.991)', 4326)::geography),
 ST_GeomFromText('LINESTRING(116.391 39.989, 116.391 39.991)', 4326));

-- Sample POIs
INSERT INTO pois (name, category, the_geom) VALUES
('South Gate', 'entrance', ST_SetSRID(ST_MakePoint(116.390, 39.988), 4326)),
('North Gate', 'entrance', ST_SetSRID(ST_MakePoint(116.390, 39.992), 4326)),
('Rose Garden', 'attraction', ST_SetSRID(ST_MakePoint(116.390, 39.990), 4326)),
('Lake Pavilion', 'attraction', ST_SetSRID(ST_MakePoint(116.391, 39.991), 4326)),
('Restroom A', 'facility', ST_SetSRID(ST_MakePoint(116.388, 39.990), 4326));
