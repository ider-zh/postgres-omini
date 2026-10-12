# Third-party components

This repository assembles independently licensed components. The table records the default Dockerfile versions and upstream license files; it does not replace those files or grant additional rights.

| Component | Default version | Upstream license | Source/license |
| --- | --- | --- | --- |
| PostgreSQL | 18 (`postgres:18-trixie`, patch version recorded at build time) | PostgreSQL License | [PostgreSQL copyright](https://www.postgresql.org/about/licence/) |
| pgvector | 0.8.4 | PostgreSQL License | [v0.8.4 LICENSE](https://github.com/pgvector/pgvector/blob/v0.8.4/LICENSE) |
| ParadeDB pg_search | 0.24.1 | AGPL-3.0 as declared upstream | [v0.24.1 LICENSE](https://github.com/paradedb/paradedb/blob/v0.24.1/LICENSE) |
| PGMQ | 1.11.1 | PostgreSQL License | [v1.11.1 LICENSE](https://github.com/pgmq/pgmq/blob/v1.11.1/LICENSE) |
| SCWS | 1.2.3 | BSD 3-Clause | [1.2.3 COPYING](https://github.com/hightman/scws/blob/1.2.3/COPYING) |
| zhparser | 2.3 | PostgreSQL License | [v2.3 COPYRIGHT](https://github.com/amutu/zhparser/blob/v2.3/COPYRIGHT) |
| TimescaleDB | 2.28.2 | Apache 2.0 and Timescale License, according to source directory | [2.28.2 LICENSE](https://github.com/timescale/timescaledb/blob/2.28.2/LICENSE), [Apache license](https://github.com/timescale/timescaledb/blob/2.28.2/LICENSE-APACHE), [Timescale license](https://github.com/timescale/timescaledb/blob/2.28.2/tsl/LICENSE-TIMESCALE), [NOTICE](https://github.com/timescale/timescaledb/blob/2.28.2/NOTICE) |

## Files included in the image

`/usr/share/doc/postgres-omini/` contains the component manifest, upstream license/notice files in per-component directories, and a short license inventory. When present in the downloaded ParadeDB package, its Debian documentation is preserved under the `pg_search` directory. Base-image and installed Debian package notices remain under `/usr/share/doc/`.

Inspect the exact component inventory with:

```bash
docker run --rm --entrypoint cat postgres-omini:local \
  /usr/share/doc/postgres-omini/components.tsv
```

The Dockerfile builds TimescaleDB with `APACHE_ONLY=OFF`, including the Timescale-licensed modules. The image's `LicenseRef-Timescale` label refers to the bundled `timescaledb/LICENSE-TIMESCALE`; this is not an Apache-only TimescaleDB distribution. Continuous aggregates are exercised by the runtime smoke test.

The OCI license label summarizes these bundled components. It is not a complete dependency SBOM or a single license for every byte in the image. Consult the corresponding upstream terms when using, modifying, or redistributing a component. The manifest records the configured component versions and the actual PostgreSQL runtime version; the CI artifacts also identify the tested/published image.
