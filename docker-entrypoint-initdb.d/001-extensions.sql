-- Use public as the default schema for extensions that do not specify one.
SET search_path = public, pg_catalog;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_search;
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS zhparser;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_ts_config AS config
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = config.cfgnamespace
    WHERE config.cfgname = 'chinese' AND namespace.nspname = 'public'
  ) THEN
    CREATE TEXT SEARCH CONFIGURATION public.chinese (PARSER = public.zhparser);
    ALTER TEXT SEARCH CONFIGURATION public.chinese
      ADD MAPPING FOR n,v,a,i,e,l WITH pg_catalog.simple;
  END IF;
END
$$;

