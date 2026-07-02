# postgres-omini

PostgreSQL 18 image with these extensions preinstalled and enabled on first database initialization:

- `pgvector` for vector similarity search
- ParadeDB `pg_search` for BM25 full-text search
- ParadeDB Jieba/Lindera/CJK tokenizers for Chinese BM25 search
- `pgmq` for Postgres-native message queues
- `zhparser` with SCWS for PostgreSQL native Chinese full-text search

## Quick start

```bash
docker compose up -d --build
psql postgres://postgres:postgres@127.0.0.1:5432/postgres
```

The init script creates all bundled extensions in the default database:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'pg_search', 'pgmq', 'zhparser')
ORDER BY extname;
```

Chinese search options:

```sql
-- Native PostgreSQL FTS with zhparser.
SELECT to_tsvector('chinese', '中文分词用于全文检索');

-- ParadeDB BM25 with Jieba tokenizer.
CREATE TABLE cn_docs (id bigserial PRIMARY KEY, body text NOT NULL);
INSERT INTO cn_docs (body) VALUES ('PostgreSQL 中文分词和向量搜索开箱即用');
CREATE INDEX cn_docs_search_idx ON cn_docs
USING bm25 (id, (body::pdb.jieba))
WITH (key_field='id');
SELECT id, pdb.score(id) FROM cn_docs WHERE body @@@ '中文搜索';
```

## Build

```bash
docker build -t postgres-omini:local .
```

The default build uses the widely deployed Debian-based `postgres:18` image. It compiles pgvector, PGMQ, SCWS, and zhparser from source, and installs the official ParadeDB `pg_search` Debian package for PostgreSQL 18.

If your network needs a proxy or a local Debian mirror:

```bash
docker build --add-host win230:100.119.20.46 \
  --build-arg APT_MIRROR=http://mirrors.aliyun.com/debian \
  --build-arg FETCH_HTTP_PROXY=http://win230:10808 \
  --build-arg FETCH_HTTPS_PROXY=http://win230:10808 \
  -t postgres-omini:local .
```

## Benchmark

```bash
./scripts/benchmark.sh
```

Options:

```bash
ROWS=100000 IMAGE=postgres-omini:bench ./scripts/benchmark.sh
```

When the build needs the same proxy arguments:

```bash
DOCKER_BUILD_ARGS="--add-host win230:100.119.20.46 --build-arg APT_MIRROR=http://mirrors.aliyun.com/debian --build-arg FETCH_HTTP_PROXY=http://win230:10808 --build-arg FETCH_HTTPS_PROXY=http://win230:10808" \
  ROWS=100000 ./scripts/benchmark.sh
```

The script builds the image, starts a temporary container, tests pgvector, pg_search, pgmq, and Chinese search paths, prints a timing report, then removes the container.

## Published image

GitHub Actions publishes to:

```text
ghcr.io/ider-zh/postgres-omini:latest
```
