-- pgRouting 4.0: manual topology via pgr_extractVertices (pgr_createTopology removed)

DROP TABLE IF EXISTS park_ways_vertices_pgr;

SELECT *
INTO park_ways_vertices_pgr
FROM pgr_extractVertices('SELECT id, the_geom AS geom FROM park_ways ORDER BY id');

-- Assign source vertices from edge start points
WITH out_going AS (
    SELECT id AS vid, unnest(out_edges) AS eid
    FROM park_ways_vertices_pgr
    WHERE out_edges IS NOT NULL
)
UPDATE park_ways AS w
SET source = o.vid
FROM out_going AS o
WHERE w.id = o.eid;

-- Assign target vertices from edge end points
WITH in_coming AS (
    SELECT id AS vid, unnest(in_edges) AS eid
    FROM park_ways_vertices_pgr
    WHERE in_edges IS NOT NULL
)
UPDATE park_ways AS w
SET target = i.vid
FROM in_coming AS i
WHERE w.id = i.eid;

-- Connectivity sanity check
DO $$
DECLARE
    missing_topology INTEGER;
    isolated_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO missing_topology
    FROM park_ways
    WHERE source IS NULL OR target IS NULL;

    IF missing_topology > 0 THEN
        RAISE EXCEPTION 'Topology incomplete: % edges missing source/target', missing_topology;
    END IF;

    SELECT COUNT(*) INTO isolated_count
    FROM park_ways_vertices_pgr v
    WHERE (v.in_edges IS NULL OR cardinality(v.in_edges) = 0)
      AND (v.out_edges IS NULL OR cardinality(v.out_edges) = 0);

    IF isolated_count > 0 THEN
        RAISE WARNING 'Found % isolated vertices in park network', isolated_count;
    END IF;
END $$;

ALTER TABLE park_ways
    ALTER COLUMN source SET NOT NULL,
    ALTER COLUMN target SET NOT NULL;
