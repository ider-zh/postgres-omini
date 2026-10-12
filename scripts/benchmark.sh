#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
IMAGE="${IMAGE:-postgres-omini:benchmark}"
CONTAINER="${CONTAINER:-postgres-omini-benchmark}"
ROWS="${ROWS:-20000}"
REPEATS="${REPEATS:-3}"
WARMUP="${WARMUP:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
CONTAINER_ID=""
export LC_NUMERIC=C

fail() {
  echo "error: $*" >&2
  exit 1
}

validate_integer() {
  local name="$1" minimum="$2" maximum="$3" value="${!1}"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${#value}" -gt 10 ]; then
    fail "${name} must be an integer between ${minimum} and ${maximum}"
  fi
  value=$((10#${value}))
  if [ "${value}" -lt "${minimum}" ] || [ "${value}" -gt "${maximum}" ]; then
    fail "${name} must be an integer between ${minimum} and ${maximum}"
  fi
  printf -v "${name}" '%d' "${value}"
}

# At least 100 rows are needed for the queue batch timings.
validate_integer ROWS 100 2147483647
validate_integer REPEATS 1 1000
validate_integer WARMUP 0 1000
[[ "${SKIP_BUILD}" == 0 || "${SKIP_BUILD}" == 1 ]] || fail "SKIP_BUILD must be 0 or 1"

cleanup() {
  if [ -n "${CONTAINER_ID}" ]; then
    echo "==> removing temporary benchmark container and anonymous volumes..." >&2
    docker rm -fv "${CONTAINER_ID}" >/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}
require docker
require sort

if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
  fail "container ${CONTAINER} already exists; choose another CONTAINER name"
fi

read -r -a BUILD_ARGS <<< "${DOCKER_BUILD_ARGS:-}"
if [ "${SKIP_BUILD}" = "1" ]; then
  echo "SKIP_BUILD=1: using existing image ${IMAGE}" >&2
else
  echo "==> building benchmark image (${IMAGE})..." >&2
  docker build --progress=plain "${BUILD_ARGS[@]}" -t "${IMAGE}" "${PROJECT_DIR}" >&2
fi

# Track the ID returned by create. A name conflict must never delete someone
# else's container; a later start/readiness failure still cleans up ours.
echo "==> starting container ${CONTAINER}..." >&2
CONTAINER_ID="$(docker create --name "${CONTAINER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" "${IMAGE}")"
docker start "${CONTAINER_ID}" >/dev/null

echo -n "==> waiting for postgres to be ready" >&2
ready=false
for ((i = 1; i <= 60; i++)); do
  if docker exec "${CONTAINER_ID}" docker-healthcheck.sh >/dev/null 2>&1; then
    ready=true
    break
  fi
  if [ $((i % 5)) -eq 0 ]; then
    echo -n " (${i} checks)" >&2
  else
    echo -n "." >&2
  fi
  sleep 1
done
echo "" >&2
if [ "${ready}" != "true" ]; then
  docker logs --tail 80 "${CONTAINER_ID}" >&2 || true
  fail "postgres initialization did not become ready after 60 checks"
fi

PSQL=(docker exec -i -e PGOPTIONS="-c client_min_messages=notice" -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_ID}" psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -v ROWS="${ROWS}" -X -q -w)

elapsed_ms() {
  local sql="$1" output seconds status
  # Bash's timer also works on hosts whose date command lacks %N support.
  # Keep psql errors visible and preserve its exit status before parsing time.
  if output="$( { TIMEFORMAT='%3R'; time "${PSQL[@]}" -c "${sql}" >/dev/null; } 2>&1)"; then
    :
  else
    status=$?
    printf '%s\n' "${output}" >&2
    return "${status}"
  fi
  seconds="${output##*$'\n'}"
  if [[ "${output}" == *$'\n'* ]]; then
    printf '%s\n' "${output%$'\n'*}" >&2
  fi
  if [[ ! "${seconds}" =~ ^([0-9]+)\.([0-9]{3})$ ]]; then
    fail "could not parse elapsed time: ${seconds}"
  fi
  printf '%d\n' "$((10#${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]}))"
}

time_sql() {
  local label="$1" sql="$2" i ms median
  local samples=() sorted=()
  echo "==> running ${label} (${WARMUP} warmup, ${REPEATS} samples)..." >&2
  for ((i = 0; i < WARMUP; i++)); do
    "${PSQL[@]}" -c "${sql}" >/dev/null
  done
  for ((i = 0; i < REPEATS; i++)); do
    ms="$(elapsed_ms "${sql}")"
    samples+=("${ms}")
  done
  while IFS= read -r ms; do
    sorted+=("${ms}")
  done < <(printf '%s\n' "${samples[@]}" | sort -n)
  median=$(( (sorted[(REPEATS - 1) / 2] + sorted[REPEATS / 2]) / 2 ))
  printf '%-39s %10s %10s %10s\n' "${label}" "${median}" "${sorted[0]}" "${sorted[REPEATS - 1]}"
}

echo "==> loading benchmark data (${ROWS} rows)..." >&2
"${PSQL[@]}" >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_search;
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS zhparser;

CREATE OR REPLACE FUNCTION _bench_notice(msg text) RETURNS void AS $$
BEGIN
  RAISE NOTICE '%', msg;
END
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_ts_config WHERE cfgname = 'chinese'
  ) THEN
    CREATE TEXT SEARCH CONFIGURATION chinese (PARSER = zhparser);
    ALTER TEXT SEARCH CONFIGURATION chinese ADD MAPPING FOR n,v,a,i,e,l WITH simple;
  END IF;
END
$$;

-- Check semantics on fixed fixtures before creating the timing workload.
SELECT _bench_notice('checking BM25 ranking on fixed documents');
CREATE TABLE bench_check_docs (id integer PRIMARY KEY, body text NOT NULL);
INSERT INTO bench_check_docs VALUES
  (1, 'postgres search'), (2, 'postgres'), (3, 'queue worker');
CREATE INDEX bench_check_docs_search_idx ON bench_check_docs
  USING bm25 (id, body) WITH (key_field='id');
DO $$
DECLARE
  top_id integer;
  top_score real;
  matched bigint;
BEGIN
  SELECT count(*) INTO matched FROM bench_check_docs WHERE body @@@ 'postgres';
  SELECT id, pdb.score(id) INTO top_id, top_score FROM bench_check_docs
    WHERE body @@@ 'postgres search' ORDER BY pdb.score(id) DESC LIMIT 1;
  IF matched <> 2 OR top_id IS DISTINCT FROM 1 OR coalesce(top_score, 0) <= 0 THEN
    RAISE EXCEPTION 'BM25 assertion failed: matches=%, top_id=%, score=%', matched, top_id, top_score;
  END IF;
END
$$;
DROP TABLE bench_check_docs;

SELECT _bench_notice('checking pgmq batch pop on an independent 120-message queue');
SELECT pgmq.create('bench_check_queue');
SELECT pgmq.send('bench_check_queue', jsonb_build_object('id', gs))
FROM generate_series(1, 120) AS gs;
DO $$
DECLARE
  before_count bigint;
  after_count bigint;
  popped_count bigint;
  unique_ids bigint;
BEGIN
  SELECT count(*) INTO before_count FROM pgmq.q_bench_check_queue;
  SELECT count(*), count(DISTINCT msg_id) INTO popped_count, unique_ids
    FROM pgmq.pop('bench_check_queue', 100);
  SELECT count(*) INTO after_count FROM pgmq.q_bench_check_queue;
  IF before_count <> 120 OR popped_count <> 100 OR unique_ids <> 100
     OR before_count - after_count <> 100 THEN
    RAISE EXCEPTION 'PGMQ batch assertion failed: before=%, returned=%, unique=%, after=%',
      before_count, popped_count, unique_ids, after_count;
  END IF;
END
$$;
SELECT pgmq.drop_queue('bench_check_queue');

SELECT _bench_notice('creating bench_docs table');
DROP TABLE IF EXISTS bench_docs;
CREATE TABLE bench_docs (
  id bigserial PRIMARY KEY,
  title text NOT NULL,
  body text NOT NULL,
  category text NOT NULL,
  embedding vector(3) NOT NULL
);

SELECT _bench_notice(format('inserting %s rows into bench_docs', :ROWS));
INSERT INTO bench_docs (title, body, category, embedding)
SELECT
  'doc ' || gs,
  CASE
    WHEN gs % 5 = 0 THEN 'postgres vector search message queue bm25'
    WHEN gs % 5 = 1 THEN 'hybrid search postgres ranking documents'
    WHEN gs % 5 = 2 THEN 'queue worker job event delivery'
    WHEN gs % 5 = 3 THEN 'semantic embedding nearest neighbor'
    ELSE 'database extension container'
  END || ' row ' || gs,
  'cat-' || (gs % 10),
  -- Coprime periods have a product above the supported ROWS range, so these
  -- synthetic 3D vectors are distinct. They are not model embeddings.
  ARRAY[(gs % 1009)::float4 / 1009,
        (gs % 1013)::float4 / 1013,
        (gs % 4093)::float4 / 4093]::vector(3)
FROM generate_series(1, :ROWS) AS gs;

SELECT _bench_notice('creating bench_cn_docs table');
DROP TABLE IF EXISTS bench_cn_docs;
CREATE TABLE bench_cn_docs (
  id bigserial PRIMARY KEY,
  body text NOT NULL,
  body_tsv tsvector GENERATED ALWAYS AS (to_tsvector('chinese', body)) STORED
);

SELECT _bench_notice(format('inserting %s rows into bench_cn_docs', :ROWS));
INSERT INTO bench_cn_docs (body)
SELECT
  CASE
    WHEN gs % 4 = 0 THEN 'PostgreSQL 中文分词 支持 全文检索 和 向量搜索'
    WHEN gs % 4 = 1 THEN '消息队列 任务处理 延迟投递 可靠消费'
    WHEN gs % 4 = 2 THEN '混合搜索 结合 BM25 关键词 和 语义向量'
    ELSE '容器镜像 开箱即用 轻量化 部署'
  END || ' 文档 ' || gs
FROM generate_series(1, :ROWS) AS gs;

SELECT _bench_notice('creating indexes on bench_docs');
CREATE INDEX bench_docs_embedding_hnsw ON bench_docs USING hnsw (embedding vector_l2_ops);
CREATE INDEX bench_docs_search_idx ON bench_docs USING bm25 (id, title, body, category) WITH (key_field='id');

SELECT _bench_notice('creating indexes on bench_cn_docs');
CREATE INDEX bench_cn_docs_zhparser_idx ON bench_cn_docs USING gin (body_tsv);
CREATE INDEX bench_cn_docs_bm25_idx ON bench_cn_docs USING bm25 (id, (body::pdb.jieba)) WITH (key_field='id');

SELECT _bench_notice(format('creating pgmq queue and sending %s messages', :ROWS));
SELECT pgmq.create('bench_queue');
SELECT pgmq.send('bench_queue', jsonb_build_object('id', gs, 'payload', 'benchmark message ' || gs))
FROM generate_series(1, :ROWS) AS gs;

SELECT _bench_notice('creating bench_metrics hypertable');
DROP TABLE IF EXISTS bench_metrics;
CREATE TABLE bench_metrics (
  time timestamptz NOT NULL,
  device text NOT NULL,
  value double precision NOT NULL
);
SELECT create_hypertable('bench_metrics', 'time');
CREATE INDEX bench_metrics_device_time_idx ON bench_metrics (device, time DESC);

SELECT _bench_notice(format('inserting %s rows into bench_metrics', :ROWS));
INSERT INTO bench_metrics (time, device, value)
SELECT now() - (gs * interval '1 second'),
       'dev-' || (gs % 100),
       random() * 100
FROM generate_series(1, :ROWS) AS gs;

SELECT _bench_notice('refreshing planner statistics');
ANALYZE bench_docs;
ANALYZE bench_cn_docs;
ANALYZE pgmq.q_bench_queue;
ANALYZE bench_metrics;

SELECT _bench_notice('data loading and fixed-fixture assertions complete');
DROP FUNCTION IF EXISTS _bench_notice(text);
SQL

echo
echo "Postgres Omini synthetic smoke timing"
echo "rows: ${ROWS}; warmup per query: ${WARMUP}; measured samples per query: ${REPEATS}"
echo "Elapsed time includes docker exec, psql startup, connection, and SQL execution."
echo "Queue samples include ROLLBACK to restore the same logical state each time."
echo "Use representative data for capacity planning and retrieval-quality evaluation."
echo
printf '%-39s %10s %10s %10s\n' "case" "median ms" "min ms" "max ms"
time_sql "pgvector top-k l2" "SELECT id FROM bench_docs ORDER BY embedding <-> '[0.25,0.5,0.75]'::vector LIMIT 25;"
time_sql "pg_search bm25 top-k" "SELECT id, pdb.score(id) FROM bench_docs WHERE body @@@ 'postgres search' ORDER BY pdb.score(id) DESC LIMIT 25;"
time_sql "pg_search filtered count" "SELECT count(*) FROM bench_docs WHERE body @@@ 'queue' AND category = 'cat-2';"
time_sql "pg_search jieba cn top-k" "SELECT id, pdb.score(id) FROM bench_cn_docs WHERE body @@@ '中文搜索' ORDER BY pdb.score(id) DESC LIMIT 25;"
time_sql "zhparser gin cn count" "SELECT count(*) FROM bench_cn_docs WHERE body_tsv @@ plainto_tsquery('chinese', '中文搜索');"
time_sql "pgmq read 100 (rollback)" "BEGIN; SELECT count(*) FROM pgmq.read('bench_queue', 30, 100); ROLLBACK;"
time_sql "pgmq pop 100 (rollback)" "BEGIN; SELECT count(*) FROM pgmq.pop('bench_queue', 100); ROLLBACK;"
time_sql "timescaledb time_bucket 1m" "SELECT time_bucket('1 minute', time) AS bucket, avg(value) FROM bench_metrics WHERE time > now() - interval '1 hour' GROUP BY bucket ORDER BY bucket DESC LIMIT 10;"
time_sql "timescaledb last point per device" "SELECT DISTINCT ON (device) device, time, value FROM bench_metrics ORDER BY device, time DESC LIMIT 100;"

echo
echo "installed extensions:"
"${PSQL[@]}" -At -c "SELECT extname || ' ' || extversion FROM pg_extension WHERE extname IN ('vector','pg_search','timescaledb','pgmq','zhparser') ORDER BY extname;"

