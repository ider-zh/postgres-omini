#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-postgres-omini:benchmark}"
CONTAINER="${CONTAINER:-postgres-omini-benchmark}"
ROWS="${ROWS:-20000}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"

cleanup() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require docker

cleanup
read -r -a BUILD_ARGS <<< "${DOCKER_BUILD_ARGS:-}"
docker build -q "${BUILD_ARGS[@]}" -t "${IMAGE}" . >/dev/null
docker run -d --name "${CONTAINER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  -p 55432:5432 \
  "${IMAGE}" >/dev/null

echo "waiting for postgres..."
for _ in $(seq 1 60); do
  if docker exec "${CONTAINER}" pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

PSQL=(docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "${CONTAINER}" psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -X -q)

time_sql() {
  local label="$1"
  local sql="$2"
  local start end ms
  start="$(date +%s%3N)"
  "${PSQL[@]}" -c "${sql}" >/dev/null
  end="$(date +%s%3N)"
  ms=$((end - start))
  printf '%-34s %8s ms\n' "${label}" "${ms}"
}

echo "loading benchmark data (${ROWS} rows)..."
"${PSQL[@]}" >/dev/null <<SQL
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_search;
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS zhparser;

DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_ts_config WHERE cfgname = 'chinese'
  ) THEN
    CREATE TEXT SEARCH CONFIGURATION chinese (PARSER = zhparser);
    ALTER TEXT SEARCH CONFIGURATION chinese ADD MAPPING FOR n,v,a,i,e,l WITH simple;
  END IF;
END
\$\$;

DROP TABLE IF EXISTS bench_docs;
CREATE TABLE bench_docs (
  id bigserial PRIMARY KEY,
  title text NOT NULL,
  body text NOT NULL,
  category text NOT NULL,
  embedding vector(3) NOT NULL
);

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
  ARRAY[(gs % 100)::float4 / 100, (gs % 50)::float4 / 50, (gs % 25)::float4 / 25]::vector(3)
FROM generate_series(1, ${ROWS}) AS gs;

DROP TABLE IF EXISTS bench_cn_docs;
CREATE TABLE bench_cn_docs (
  id bigserial PRIMARY KEY,
  body text NOT NULL,
  body_tsv tsvector GENERATED ALWAYS AS (to_tsvector('chinese', body)) STORED
);

INSERT INTO bench_cn_docs (body)
SELECT
  CASE
    WHEN gs % 4 = 0 THEN 'PostgreSQL 中文分词 支持 全文检索 和 向量搜索'
    WHEN gs % 4 = 1 THEN '消息队列 任务处理 延迟投递 可靠消费'
    WHEN gs % 4 = 2 THEN '混合搜索 结合 BM25 关键词 和 语义向量'
    ELSE '容器镜像 开箱即用 轻量化 部署'
  END || ' 文档 ' || gs
FROM generate_series(1, ${ROWS}) AS gs;

CREATE INDEX bench_docs_embedding_hnsw ON bench_docs USING hnsw (embedding vector_l2_ops);
CREATE INDEX bench_docs_search_idx ON bench_docs USING bm25 (id, title, body, category) WITH (key_field='id');
CREATE INDEX bench_cn_docs_zhparser_idx ON bench_cn_docs USING gin (body_tsv);
CREATE INDEX bench_cn_docs_bm25_idx ON bench_cn_docs USING bm25 (id, (body::pdb.jieba)) WITH (key_field='id');

SELECT pgmq.create('bench_queue');
SELECT pgmq.send('bench_queue', jsonb_build_object('id', gs, 'payload', 'benchmark message ' || gs))
FROM generate_series(1, ${ROWS}) AS gs;
SQL

echo
echo "Postgres Omini benchmark report"
echo "rows: ${ROWS}"
echo
time_sql "pgvector top-k l2" "SELECT id FROM bench_docs ORDER BY embedding <-> '[0.25,0.5,0.75]'::vector LIMIT 25;"
time_sql "pg_search bm25 match" "SELECT id, pdb.score(id) FROM bench_docs WHERE body @@@ 'postgres search' ORDER BY pdb.score(id) LIMIT 25;"
time_sql "pg_search filtered match" "SELECT count(*) FROM bench_docs WHERE body @@@ 'queue' AND category = 'cat-2';"
time_sql "pg_search jieba cn match" "SELECT id, pdb.score(id) FROM bench_cn_docs WHERE body @@@ '中文搜索' ORDER BY pdb.score(id) LIMIT 25;"
time_sql "zhparser gin cn match" "SELECT count(*) FROM bench_cn_docs WHERE body_tsv @@ plainto_tsquery('chinese', '中文搜索');"
time_sql "pgmq read 100" "SELECT count(*) FROM pgmq.read('bench_queue', 30, 100);"
time_sql "pgmq pop 100" "SELECT count(*) FROM generate_series(1, 100), LATERAL pgmq.pop('bench_queue');"

echo
echo "installed extensions:"
"${PSQL[@]}" -At -c "SELECT extname || ' ' || extversion FROM pg_extension WHERE extname IN ('vector','pg_search','pgmq','zhparser') ORDER BY extname;"

echo
echo "cleaning up..."
