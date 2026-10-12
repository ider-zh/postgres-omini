# Operations and upgrades

This image supports PostgreSQL 18 on Debian trixie. Treat a new empty database, an existing PostgreSQL 18 cluster, and a PostgreSQL major upgrade as separate operations. Test changes against a restored copy before replacing a database that contains important data.

## Record the running configuration

For the default Compose user and database:

```bash
docker compose exec -T postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c 'SELECT version();' \
  -c 'SHOW data_directory;' \
  -c 'SHOW shared_preload_libraries;' \
  -c 'SELECT extname, extversion FROM pg_extension ORDER BY extname;'
docker compose exec -T postgres cat /usr/share/doc/postgres-omini/components.tsv
docker inspect --format '{{json .Mounts}}' "$(docker compose ps -q postgres)"
```

Substitute your configured user and database when they differ. Repeat the extension inventory for every application database. `components.tsv` describes files bundled in the image; `pg_extension` describes extensions installed in the current database. Their versions can differ on an existing volume until an extension migration is performed.

Record the running image digest as well as its tag. `latest` and `main` can change, and a project tag such as `v18.4.1` is not the PostgreSQL server version.

## Existing volumes and the PG18 mount fix

The current Compose file mounts its named volume at `/var/lib/postgresql`. The PostgreSQL 18 base image stores the cluster at `/var/lib/postgresql/18/docker`. This follows the [official PostgreSQL image's PG18 layout](https://github.com/docker-library/docs/blob/master/postgres/README.md#pgdata).

Earlier revisions mounted `/var/lib/postgresql/data`. That path is not the default PG18 data directory. Depending on the image revision and existing mounts, startup can fail or the actual data can reside in another volume. The presence of a named volume alone does not prove it contains the cluster.

Before adopting the corrected Compose file:

1. Keep the existing deployment available long enough to record `SHOW data_directory`, the container's mounts, the image digest, and all database/extension versions. Preserve the previous Compose file and its project name.
2. Locate the volume that actually contains the reported data directory. Retain it and the old container until a backup and recovery test succeed. Do not run `docker compose down --volumes` or volume-pruning commands on this deployment.
3. Make a logical backup of every application database and any roles/tablespaces they require. For physical backups or filesystem copies, use a PostgreSQL-supported backup method; an ordinary copy of a running data directory is not a consistent backup.
4. Restore into a separate deployment with a fresh, correctly mounted named volume and compatible extension versions. Verify application reads/writes, search indexes, queue state, and TimescaleDB aggregates before redirecting clients.
5. Keep the original deployment and backups until rollback is no longer required. After an upgrade, rollback may require restoring the old backup rather than starting the old image against changed data files.

Changing a mount destination does not move data or convert an old directory layout. Reusing the old named volume without checking its contents can make a new empty cluster appear to be the original database. The repository smoke test checks fresh PG18 deployment persistence; it does not migrate or validate your existing production data.

## Back up and rehearse restoration

For a default deployment, save one database and cluster globals outside its volume:

```bash
# Use a new destination directory for each backup to avoid overwriting one.
backup_dir="backup-$(date -u +%Y%m%dT%H%M%SZ)"
umask 077
mkdir "$backup_dir"
docker compose exec -T postgres pg_dump -U postgres -d postgres -Fc \
  > "$backup_dir/postgres.dump"
docker compose exec -T postgres pg_dumpall -U postgres --globals-only \
  > "$backup_dir/globals.sql"
docker compose exec -T postgres cat /usr/share/doc/postgres-omini/components.tsv \
  > "$backup_dir/components.tsv"
```

Check each command's exit status and retain the configuration/version inventory with the backup. Repeat `pg_dump` for every application database; a single database dump does not include other databases or cluster roles. The globals file can contain role password hashes and must remain private. Review it before restoring into a cluster with pre-existing roles or tablespaces.

Rehearse restoration into an isolated database with compatible extension binaries. For TimescaleDB, follow the upstream [whole-database migration procedure](https://www.tigerdata.com/docs/deploy/self-hosted/migration/entire-database), including its extension-version requirements and `timescaledb_pre_restore()` / `timescaledb_post_restore()` steps. Validate Timescale metadata and continuous aggregates as well as ordinary rows. Do not assume a plain SQL import alone proves all extension objects are usable.

See PostgreSQL's [pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html), [pg_dumpall](https://www.postgresql.org/docs/18/app-pg-dumpall.html), and [backup documentation](https://www.postgresql.org/docs/18/backup.html) for backup scope and recovery methods.

## Initialization is only for an empty cluster

The official entrypoint executes `/docker-entrypoint-initdb.d/001-extensions.sql` only when it initializes an empty `PGDATA`. It enables the bundle in `POSTGRES_DB`, which defaults to `POSTGRES_USER` in the base image; this project's Compose defaults both to `postgres`.

An existing cluster keeps its configuration and database objects. A database created later does not inherit these extensions from `postgres`. To enable the bundle in a newly created application database, after verifying its settings and permissions:

```bash
docker compose exec -T postgres psql -X -U postgres -d your_database \
  -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/001-extensions.sql
```

The script uses `CREATE EXTENSION IF NOT EXISTS`; it does not upgrade extensions that are already installed. It creates `public.chinese` only if that configuration does not already exist, and does not overwrite an existing configuration's mappings.

The health check checks the configured default database for all five extensions and `public.chinese`. If the server is running but unhealthy after reusing a volume, inspect the logs and database inventory. An absent extension or incomplete earlier initialization requires an explicit repair in that database.

## Updating an existing PostgreSQL 18 cluster

Before changing the image, record installed versions and check each extension's supported update path. Build and test the candidate, back up the cluster, and rehearse the upgrade on a copy.

The image appends `pg_search,timescaledb` to `postgresql.conf.sample` for new clusters. Replacing the image does not update an existing `postgresql.conf` or `postgresql.auto.conf`. Merge these libraries into the existing `shared_preload_libraries` value while preserving other required libraries, then restart PostgreSQL. Check the effective setting with `SHOW shared_preload_libraries`.

Install the required extension binaries before applying any extension SQL updates. Run supported `ALTER EXTENSION ... UPDATE` operations separately in each database that uses the extension; use explicit target versions and upstream migration guidance. Do not blindly update every extension just because a new image is available. ParadeDB upgrades can require index migration/rebuilding, and TimescaleDB versions have PostgreSQL compatibility and upgrade-path requirements.

TimescaleDB updates must run in a fresh session before the old version is loaded; use `psql -X` and issue the update as the first SQL command. Follow the upstream [TimescaleDB upgrade documentation](https://www.tigerdata.com/docs/deploy/self-hosted/upgrades/minor-upgrade) and [troubleshooting notes](https://www.tigerdata.com/docs/deploy/self-hosted/troubleshooting) for the exact source/target versions. Afterwards, verify `pg_extension`, application queries, BM25/vector indexes, queue operations, hypertables, and continuous aggregates.

Changing `POSTGRES_PASSWORD` in `.env` does not rotate an existing database role's password. Rotate it explicitly in PostgreSQL, then update clients and the health-check credentials together.

## PostgreSQL major upgrades

This Dockerfile explicitly supports PostgreSQL 18. Overriding `POSTGRES_VERSION` is not a supported migration mechanism. Never start a PostgreSQL 18 server directly against a data directory created by an incompatible major version.

Use a rehearsed logical dump/restore or [pg_upgrade](https://www.postgresql.org/docs/18/pgupgrade.html) procedure, with compatible old/new PostgreSQL binaries and every required extension available for both versions. Check extension support and required intermediate upgrades first. A `pg_upgrade --check` is useful but does not substitute for extension and application validation on the migrated database.

Keep backups, the old image digest, and a tested recovery plan until the new cluster has been accepted. A successful container start alone does not establish that an upgrade succeeded.
