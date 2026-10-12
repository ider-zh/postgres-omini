\set ON_ERROR_STOP on
\echo Checking automatic initialization
SET statement_timeout = '60s';
SET TIME ZONE 'UTC';

-- Do not CREATE EXTENSION here: missing initialization must fail the test.
CREATE SCHEMA omni_smoke;
CREATE FUNCTION omni_smoke.assert_true(ok boolean, description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'smoke test failed: %', description;
  END IF;
END
$$;

SELECT omni_smoke.assert_true(
  current_setting('server_version_num')::integer / 10000 = 18,
  'the server must be PostgreSQL 18'
);
SELECT omni_smoke.assert_true(
  (SELECT count(*) = 5 FROM pg_extension
   WHERE extname IN ('vector', 'pg_search', 'timescaledb', 'pgmq', 'zhparser')),
  'all five extensions must already be installed by the entrypoint'
);
SELECT omni_smoke.assert_true(
  EXISTS (
    SELECT 1 FROM pg_ts_config AS cfg
    JOIN pg_ts_parser AS parser ON parser.oid = cfg.cfgparser
    WHERE cfg.cfgnamespace = 'public'::regnamespace
      AND cfg.cfgname = 'chinese' AND parser.prsname = 'zhparser'
  ),
  'public.chinese must already use the zhparser parser'
);
SELECT extname, extversion FROM pg_extension
WHERE extname IN ('vector', 'pg_search', 'timescaledb', 'pgmq', 'zhparser')
ORDER BY extname;

\echo Checking pgvector exact and HNSW searches
CREATE TABLE omni_smoke.vectors (id integer PRIMARY KEY, embedding vector(3) NOT NULL);
INSERT INTO omni_smoke.vectors VALUES
  (1, '[0,0,0]'), (2, '[1,0,0]'), (3, '[0,2,0]'), (4, '[0,0,3]');
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.vectors
        ORDER BY embedding <-> '[0,0,0]'::vector LIMIT 3) = ARRAY[1,2,3],
  'exact vector search must return the known nearest points'
);
CREATE INDEX vectors_hnsw ON omni_smoke.vectors USING hnsw (embedding vector_l2_ops);
SET enable_seqscan = off;
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.vectors
        ORDER BY embedding <-> '[0,0,0]'::vector LIMIT 3) = ARRAY[1,2,3],
  'HNSW search must return the known nearest points'
);
RESET enable_seqscan;

\echo Checking BM25 matching and descending relevance
CREATE TABLE omni_smoke.docs (id integer PRIMARY KEY, body text NOT NULL);
INSERT INTO omni_smoke.docs VALUES
  (1, 'postgres postgres postgres postgres'),
  (2, 'postgres database indexing query engine system operations storage ranking document vector queue'),
  (3, 'oranges apples bananas');
CREATE INDEX docs_bm25 ON omni_smoke.docs USING bm25 (id, body) WITH (key_field = 'id');
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.docs WHERE body @@@ 'postgres'
        ORDER BY pdb.score(id) DESC, id) = ARRAY[1,2],
  'BM25 must match only postgres documents and rank the stronger match first'
);
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.docs WHERE body @@@ 'oranges') = ARRAY[3],
  'BM25 must return the expected document ID'
);

\echo Checking Jieba Chinese BM25
CREATE TABLE omni_smoke.chinese_docs (id integer PRIMARY KEY, body text NOT NULL);
INSERT INTO omni_smoke.chinese_docs VALUES
  (1, '我们都有光明的前途'),
  (2, '李宇给公安局打了电话'),
  (3, '这项政策旨在促进劳动力转移就业');
CREATE INDEX chinese_docs_bm25 ON omni_smoke.chinese_docs
USING bm25 (id, (body::pdb.jieba)) WITH (key_field = 'id');
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.chinese_docs WHERE body @@@ '光明') = ARRAY[1],
  'Jieba must segment the first Chinese document'
);
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.chinese_docs WHERE body @@@ '就业') = ARRAY[3],
  'Jieba must match a word inside an unspaced Chinese sentence'
);

\echo Checking native Chinese FTS and GIN
CREATE TABLE omni_smoke.native_chinese (
  id integer PRIMARY KEY,
  body text NOT NULL,
  body_tsv tsvector GENERATED ALWAYS AS (to_tsvector('public.chinese', body)) STORED
);
INSERT INTO omni_smoke.native_chinese (id, body) VALUES
  (1, '保障房建设需要资金投入'), (2, '海洋生物与苹果种植');
CREATE INDEX native_chinese_gin ON omni_smoke.native_chinese USING gin (body_tsv);
SELECT omni_smoke.assert_true(
  numnode(plainto_tsquery('public.chinese', '资金')) > 0,
  'zhparser must produce searchable tokens'
);
SET enable_seqscan = off;
SELECT omni_smoke.assert_true(
  ARRAY(SELECT id FROM omni_smoke.native_chinese
        WHERE body_tsv @@ plainto_tsquery('public.chinese', '资金')) = ARRAY[1],
  'zhparser/GIN must match the expected Chinese document'
);
RESET enable_seqscan;

\echo Checking PGMQ visibility, retry, archive, delete, and batch pop
-- Each lifecycle has its own queue, so an earlier read cannot hide pop inputs.
-- v1.11.1 provides pop(queue, qty) and set_vt(queue, id, seconds).
DO $$
DECLARE
  first_id bigint;
  second_id bigint;
  reset_id bigint;
  sent_id bigint;
  sent_ids bigint[] := ARRAY[]::bigint[];
  popped_ids bigint[];
  received pgmq.message_record;
  n integer;
BEGIN
  PERFORM pgmq.create('omni_smoke_retry');
  SELECT send INTO STRICT first_id
  FROM pgmq.send('omni_smoke_retry', '{"purpose":"retry"}'::jsonb);
  SELECT * INTO STRICT received FROM pgmq.read('omni_smoke_retry', 30, 1);
  PERFORM omni_smoke.assert_true(
    received.msg_id = first_id AND received.read_ct = 1
      AND received.message = '{"purpose":"retry"}'::jsonb,
    'PGMQ read must return the sent message and increment read_ct'
  );
  PERFORM omni_smoke.assert_true(
    (SELECT count(*) = 0 FROM pgmq.read('omni_smoke_retry', 30, 1)),
    'a message must be invisible until its visibility timeout expires'
  );
  SELECT msg_id INTO STRICT reset_id FROM pgmq.set_vt('omni_smoke_retry', first_id, 0);
  PERFORM omni_smoke.assert_true(reset_id = first_id, 'set_vt must update the expected message');
  SELECT * INTO STRICT received FROM pgmq.read('omni_smoke_retry', 30, 1);
  PERFORM omni_smoke.assert_true(
    received.msg_id = first_id AND received.read_ct = 2,
    'a visible message must be redelivered with the same ID and a second read'
  );
  PERFORM omni_smoke.assert_true(pgmq.archive('omni_smoke_retry', first_id), 'archive must succeed');
  PERFORM omni_smoke.assert_true(
    (SELECT count(*) = 0 FROM pgmq.q_omni_smoke_retry)
      AND (SELECT count(*) = 1 FROM pgmq.a_omni_smoke_retry
           WHERE msg_id = first_id AND message = '{"purpose":"retry"}'::jsonb),
    'archive must remove the live message and retain its ID and payload'
  );

  PERFORM pgmq.create('omni_smoke_delete');
  SELECT send INTO STRICT first_id FROM pgmq.send('omni_smoke_delete', '{"n":1}'::jsonb);
  SELECT send INTO STRICT second_id FROM pgmq.send('omni_smoke_delete', '{"n":2}'::jsonb);
  PERFORM omni_smoke.assert_true(first_id <> second_id, 'send must allocate distinct message IDs');
  PERFORM omni_smoke.assert_true(pgmq.delete('omni_smoke_delete', first_id), 'delete must succeed');
  PERFORM omni_smoke.assert_true(
    ARRAY(SELECT msg_id FROM pgmq.q_omni_smoke_delete) = ARRAY[second_id],
    'delete must remove only the selected message'
  );
  PERFORM omni_smoke.assert_true(
    NOT pgmq.delete('omni_smoke_delete', first_id),
    'deleting an absent message must return false'
  );
  PERFORM omni_smoke.assert_true(pgmq.delete('omni_smoke_delete', second_id), 'delete must remove the remaining message');
  PERFORM omni_smoke.assert_true(
    (SELECT count(*) = 0 FROM pgmq.q_omni_smoke_delete)
      AND (SELECT count(*) = 0 FROM pgmq.a_omni_smoke_delete),
    'delete must empty the queue without archiving messages'
  );

  PERFORM pgmq.create('omni_smoke_pop');
  FOR n IN 1..3 LOOP
    SELECT send INTO STRICT sent_id FROM pgmq.send('omni_smoke_pop', jsonb_build_object('n', n));
    sent_ids := array_append(sent_ids, sent_id);
  END LOOP;
  SELECT array_agg(msg_id ORDER BY msg_id) INTO popped_ids FROM pgmq.pop('omni_smoke_pop', 2);
  PERFORM omni_smoke.assert_true(
    popped_ids = sent_ids[1:2],
    'batch pop must return exactly the first two message IDs'
  );
  SELECT array_agg(msg_id ORDER BY msg_id) INTO popped_ids FROM pgmq.pop('omni_smoke_pop', 2);
  PERFORM omni_smoke.assert_true(
    popped_ids = sent_ids[3:3],
    'the next pop must return only the remaining message'
  );
  PERFORM omni_smoke.assert_true(
    (SELECT count(*) = 0 FROM pgmq.pop('omni_smoke_pop', 2))
      AND (SELECT count(*) = 0 FROM pgmq.q_omni_smoke_pop),
    'pop must permanently remove messages and return no rows for an empty queue'
  );
END
$$;

\echo Checking TimescaleDB hypertables and continuous aggregates
CREATE TABLE omni_smoke.metrics (time timestamptz NOT NULL, device text NOT NULL, value double precision NOT NULL);
SELECT create_hypertable('omni_smoke.metrics', 'time', chunk_time_interval => interval '1 day');
INSERT INTO omni_smoke.metrics VALUES
  ('2020-01-01 00:01:00+00', 'a', 10),
  ('2020-01-01 00:02:00+00', 'a', 30),
  ('2020-01-01 00:06:00+00', 'a', 50);
SELECT omni_smoke.assert_true(
  EXISTS (SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = 'omni_smoke' AND hypertable_name = 'metrics'),
  'metrics must actually be a TimescaleDB hypertable'
);
SELECT omni_smoke.assert_true(
  (SELECT array_agg(mean ORDER BY bucket) FROM (
    SELECT time_bucket('5 minutes', time) AS bucket, avg(value) AS mean
    FROM omni_smoke.metrics GROUP BY 1
  ) AS buckets) = ARRAY[20,50]::double precision[],
  'time_bucket must produce the expected aggregates'
);
-- Materialized-only prevents real-time reads from hiding a broken refresh.
-- This also exercises the Timescale-licensed module shipped by the default build.
CREATE MATERIALIZED VIEW omni_smoke.metrics_5m
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT time_bucket('5 minutes', time) AS bucket, device, avg(value) AS mean
FROM omni_smoke.metrics GROUP BY 1, 2 WITH NO DATA;
CALL refresh_continuous_aggregate(
  'omni_smoke.metrics_5m', '2020-01-01 00:00:00+00'::timestamptz, '2020-01-01 00:10:00+00'::timestamptz
);
SELECT omni_smoke.assert_true(
  (SELECT array_agg(mean ORDER BY bucket) FROM omni_smoke.metrics_5m) = ARRAY[20,50]::double precision[],
  'continuous aggregate refresh must materialize the expected values'
);
INSERT INTO omni_smoke.metrics VALUES ('2020-01-01 00:03:00+00', 'a', 50);
CALL refresh_continuous_aggregate(
  'omni_smoke.metrics_5m', '2020-01-01 00:00:00+00'::timestamptz, '2020-01-01 00:10:00+00'::timestamptz
);
SELECT omni_smoke.assert_true(
  (SELECT array_agg(mean ORDER BY bucket) FROM omni_smoke.metrics_5m) = ARRAY[30,50]::double precision[],
  'a second refresh must incorporate newly inserted source rows'
);

\echo Saving a unique persistence probe
CREATE TABLE omni_smoke.persistence_probe (token text PRIMARY KEY, system_identifier text NOT NULL);
INSERT INTO omni_smoke.persistence_probe
SELECT :'probe_token', system_identifier::text FROM pg_control_system();
