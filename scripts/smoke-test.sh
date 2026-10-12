#!/usr/bin/env bash
# Exercise the actual Compose deployment against a locally built/loaded image.
# Every invocation owns a separate Compose project and removes only its resources.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

command -v docker >/dev/null 2>&1 || {
  echo "error: docker is required" >&2
  exit 1
}
docker compose version >/dev/null

export POSTGRES_OMINI_IMAGE="${POSTGRES_OMINI_IMAGE:-postgres-omini:local}"
export POSTGRES_USER=postgres
export POSTGRES_DB=postgres
export POSTGRES_HOST_IP=127.0.0.1
export PGHOST_PORT="${PGHOST_PORT:-0}"
# This is a disposable database. Do not reuse a developer's real credentials.
export POSTGRES_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
PROBE_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
SMOKE_PROJECT="postgres-omini-smoke-${PROBE_TOKEN:0:16}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"
if [[ ! "${SMOKE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: SMOKE_TIMEOUT must be a positive number of seconds" >&2
  exit 1
fi

# Never pull a different image while testing a build that is about to be published.
docker image inspect "${POSTGRES_OMINI_IMAGE}" >/dev/null
COMPOSE=(docker compose --project-name "${SMOKE_PROJECT}" --file "${PROJECT_ROOT}/docker-compose.yml")

cleanup() {
  local result=$?
  local cleanup_result=0
  trap - EXIT INT TERM
  if (( result != 0 )); then
    echo "==> smoke test failed; Compose status and recent logs follow" >&2
    "${COMPOSE[@]}" ps --all >&2 || true
    "${COMPOSE[@]}" logs --no-color --tail 200 >&2 || true
  fi
  "${COMPOSE[@]}" down --volumes --remove-orphans --timeout 10 >&2 || cleanup_result=$?
  # Preserve a test failure even if cleanup also fails.
  if (( result == 0 && cleanup_result != 0 )); then
    result=${cleanup_result}
  fi
  exit "${result}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

psql_in_container() {
  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" -e PGCONNECT_TIMEOUT=5 \
    postgres psql -X --no-password --host=127.0.0.1 \
      --username=postgres --dbname=postgres --set=ON_ERROR_STOP=1 "$@"
}

wait_for_sql() {
  local started=${SECONDS}
  local container_id state
  echo "==> waiting for the final PostgreSQL server to accept TCP SQL" >&2
  while (( SECONDS - started < SMOKE_TIMEOUT )); do
    # The official entrypoint's temporary initialization server has no TCP
    # listener. A successful TCP query therefore cannot race its init scripts.
    if [[ "$(psql_in_container -Atqc 'SELECT 1' 2>/dev/null)" == "1" ]]; then
      return 0
    fi
    container_id="$("${COMPOSE[@]}" ps --all --quiet postgres)"
    if [[ -n "${container_id}" ]]; then
      state="$(docker inspect --format '{{.State.Status}}' "${container_id}")"
      if [[ "${state}" == "exited" || "${state}" == "dead" ]]; then
        echo "error: PostgreSQL container is ${state}" >&2
        return 1
      fi
    fi
    sleep 1
  done
  echo "error: TCP SQL was not ready within ${SMOKE_TIMEOUT} seconds" >&2
  return 1
}

assert_data_volume() {
  local container_id data_directory pgdata project_label volume_label
  container_id="$("${COMPOSE[@]}" ps --quiet postgres)"
  data_directory="$(psql_in_container -Atqc 'SHOW data_directory')"
  pgdata="$("${COMPOSE[@]}" exec -T postgres printenv PGDATA)"
  if [[ "${data_directory}" != "${pgdata}" || "${data_directory}" != /var/lib/postgresql/18/* ]]; then
    echo "error: unexpected PG18 data directory: ${data_directory}; PGDATA=${pgdata}" >&2
    return 1
  fi
  CURRENT_DATA_VOLUME="$(docker inspect --format \
    '{{range .Mounts}}{{if and (eq .Type "volume") (eq .Destination "/var/lib/postgresql")}}{{.Name}}{{end}}{{end}}' \
    "${container_id}")"
  if [[ -z "${CURRENT_DATA_VOLUME}" ]]; then
    echo "error: /var/lib/postgresql is not backed by the Compose named volume" >&2
    return 1
  fi
  project_label="$(docker volume inspect --format '{{index .Labels "com.docker.compose.project"}}' "${CURRENT_DATA_VOLUME}")"
  volume_label="$(docker volume inspect --format '{{index .Labels "com.docker.compose.volume"}}' "${CURRENT_DATA_VOLUME}")"
  if [[ "${project_label}" != "${SMOKE_PROJECT}" || "${volume_label}" != "postgres-omini-data" ]]; then
    echo "error: PostgreSQL is using a volume outside this test project" >&2
    return 1
  fi
  printf '==> PGDATA=%s; named volume=%s\n' "${data_directory}" "${CURRENT_DATA_VOLUME}" >&2
}

echo "==> starting ${POSTGRES_OMINI_IMAGE} in isolated project ${SMOKE_PROJECT}" >&2
"${COMPOSE[@]}" up --detach --no-build --pull never postgres
wait_for_sql
assert_data_volume
INITIAL_CONTAINER="$("${COMPOSE[@]}" ps --quiet postgres)"
INITIAL_DATA_VOLUME="${CURRENT_DATA_VOLUME}"

echo "==> checking automatic initialization and extension behavior" >&2
"${COMPOSE[@]}" exec -T postgres docker-healthcheck.sh
psql_in_container --set=probe_token="${PROBE_TOKEN}" < "${PROJECT_ROOT}/tests/smoke.sql"

echo "==> recreating the container while retaining the named volume" >&2
# Deliberately use down/up, not restart: a misplaced anonymous data volume can
# survive restart yet silently give a fresh database when the container changes.
"${COMPOSE[@]}" down --timeout 10
"${COMPOSE[@]}" up --detach --no-build --pull never postgres
wait_for_sql
RECREATED_CONTAINER="$("${COMPOSE[@]}" ps --quiet postgres)"
if [[ -z "${RECREATED_CONTAINER}" || "${RECREATED_CONTAINER}" == "${INITIAL_CONTAINER}" ]]; then
  echo "error: the persistence check did not create a new container" >&2
  exit 1
fi
assert_data_volume
if [[ "${CURRENT_DATA_VOLUME}" != "${INITIAL_DATA_VOLUME}" ]]; then
  echo "error: the recreated container is using a different data volume" >&2
  exit 1
fi
"${COMPOSE[@]}" exec -T postgres docker-healthcheck.sh
psql_in_container --set=probe_token="${PROBE_TOKEN}" < "${PROJECT_ROOT}/tests/persistence.sql"

echo "==> smoke test passed: initialization, five extensions, Chinese search, and data persistence" >&2
