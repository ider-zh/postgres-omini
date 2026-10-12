#!/bin/sh
set -eu

# The temporary initdb server listens only on its Unix socket. Checking TCP
# ensures initialization finished before this container is reported healthy.
if [ -n "${POSTGRES_PASSWORD_FILE:-}" ]; then
    PGPASSWORD=$(cat "${POSTGRES_PASSWORD_FILE}")
else
    PGPASSWORD=${POSTGRES_PASSWORD:-}
fi
export PGPASSWORD
export PGCONNECT_TIMEOUT=3

ready=$(psql --no-psqlrc --no-password --host=127.0.0.1 \
    --username="${POSTGRES_USER:-postgres}" \
    --dbname="${POSTGRES_DB:-${POSTGRES_USER:-postgres}}" \
    --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="
        SELECT (
            SELECT count(*) = 5
            FROM pg_catalog.pg_extension
            WHERE extname IN ('vector', 'pg_search', 'timescaledb', 'pgmq', 'zhparser')
        ) AND EXISTS (
            SELECT 1
            FROM pg_catalog.pg_ts_config AS config
            JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = config.cfgnamespace
            WHERE config.cfgname = 'chinese' AND namespace.nspname = 'public'
        );
    ")

[ "$ready" = t ]
