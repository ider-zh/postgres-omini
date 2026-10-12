\set ON_ERROR_STOP on
\echo Checking data and extension objects after container recreation
SET statement_timeout = '60s';
SET TIME ZONE 'UTC';

SELECT omni_smoke.assert_true(
  (SELECT count(*) = 1 FROM omni_smoke.persistence_probe)
    AND EXISTS (
      SELECT 1 FROM omni_smoke.persistence_probe AS probe
      CROSS JOIN pg_control_system() AS control
      WHERE probe.token = :'probe_token'
        AND probe.system_identifier = control.system_identifier::text
    ),
  'the same initialized database and unique probe must survive container recreation'
);
SELECT omni_smoke.assert_true(
  (SELECT count(*) = 5 FROM pg_extension
   WHERE extname IN ('vector', 'pg_search', 'timescaledb', 'pgmq', 'zhparser')),
  'all five extensions must remain installed'
);
SET enable_seqscan = off;
SELECT omni_smoke.assert_true(
  (SELECT count(*) = 4 FROM omni_smoke.vectors)
    AND ARRAY(SELECT id FROM omni_smoke.vectors
              ORDER BY embedding <-> '[0,0,0]'::vector LIMIT 3) = ARRAY[1,2,3],
  'vector rows and the HNSW index must survive recreation'
);
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.native_chinese
        WHERE body_tsv @@ plainto_tsquery('public.chinese', '资金')) = ARRAY[1],
  'native Chinese data, configuration, and GIN index must survive recreation'
);
RESET enable_seqscan;
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.docs WHERE body @@@ 'postgres'
        ORDER BY pdb.score(id) DESC, id) = ARRAY[1,2],
  'BM25 documents and index must survive recreation'
);
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.chinese_docs WHERE body @@@ '就业') = ARRAY[3],
  'Jieba documents and index must survive recreation'
);
SELECT omni_smoke.assert_true(
  (SELECT count(*) = 0 FROM pgmq.q_omni_smoke_retry)
    AND (SELECT count(*) = 1 FROM pgmq.a_omni_smoke_retry
         WHERE message = '{"purpose":"retry"}'::jsonb AND read_ct = 2),
  'queue state and archived messages must survive recreation'
);
SELECT omni_smoke.assert_true(
  (SELECT count(*) = 4 FROM omni_smoke.metrics)
    AND (SELECT array_agg(mean ORDER BY bucket) FROM omni_smoke.metrics_5m)
        = ARRAY[30,50]::double precision[],
  'hypertable rows and materialized aggregates must survive recreation'
);
\echo Persistence assertions passed
