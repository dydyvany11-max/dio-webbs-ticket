#!/usr/bin/env bash
set -Eeuo pipefail

# Quick commands (run from project root):
# 1) Start services:
#    docker compose up -d postgres postgres-backup
#
# 2) Prepare smoke data:
#    docker compose exec -T postgres psql -U diocontickets -d diocontickets_db -c "CREATE TABLE IF NOT EXISTS public.backup_smoke(id int primary key, note text); INSERT INTO public.backup_smoke(id,note) VALUES (1,'before_backup') ON CONFLICT (id) DO UPDATE SET note=EXCLUDED.note;"
#
# 3) Create backup now:
#    docker compose run --rm postgres-backup /backup.sh
#
# 4) Break data:
#    docker compose exec -T postgres psql -U diocontickets -d diocontickets_db -c "UPDATE public.backup_smoke SET note='broken' WHERE id=1;"
#
# 5) Restore last backup:
#    bash scripts/restore-postgres-backup.sh
#
# 6) Verify restore result:
#    docker compose exec -T postgres psql -U diocontickets -d diocontickets_db -c "SELECT * FROM public.backup_smoke;"
#
usage() {
  cat <<'EOF'
Usage:
  bash scripts/restore-postgres-backup.sh [--file <path>] [--no-reset]
  bash scripts/restore-postgres-backup.sh [<path-to-backup>]

Description:
  Restores PostgreSQL from .sql or .sql.gz backup using docker compose.
  By default, the script resets the target database before restore.

Options:
  --file <path>  Path to backup file (.sql or .sql.gz).
  --no-reset     Do not drop/recreate database before restore.
  -h, --help     Show this help.

Examples:
  bash scripts/restore-postgres-backup.sh
  bash scripts/restore-postgres-backup.sh backups/postgres/last/app-20260428-030001.sql.gz
  bash scripts/restore-postgres-backup.sh --file backups/postgres/last/app-20260428-030001.sql.gz --no-reset
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUPS_DIR="${PROJECT_ROOT}/backups/postgres"

backup_file=""
reset_db="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || { echo "Error: --file requires a value" >&2; exit 1; }
      backup_file="$2"
      shift 2
      ;;
    --no-reset)
      reset_db="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown option '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "${backup_file}" ]]; then
        echo "Error: backup file is already specified: '${backup_file}'" >&2
        exit 1
      fi
      backup_file="$1"
      shift
      ;;
  esac
done

cd "${PROJECT_ROOT}"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

: "${POSTGRES_USER:?POSTGRES_USER is not set. Add it to .env}"
: "${POSTGRES_DB:?POSTGRES_DB is not set. Add it to .env}"

if [[ -z "${backup_file}" ]]; then
  if [[ ! -d "${BACKUPS_DIR}" ]]; then
    echo "Error: backups directory not found: ${BACKUPS_DIR}" >&2
    exit 1
  fi

  backup_file="$(find "${BACKUPS_DIR}" -type f \( -name '*.sql.gz' -o -name '*.sql' \) | sort | tail -n 1)"
  if [[ -z "${backup_file}" ]]; then
    echo "Error: no backup files found in ${BACKUPS_DIR}" >&2
    exit 1
  fi
fi

if [[ ! -f "${backup_file}" ]]; then
  if [[ -f "${PROJECT_ROOT}/${backup_file}" ]]; then
    backup_file="${PROJECT_ROOT}/${backup_file}"
  else
    echo "Error: backup file not found: ${backup_file}" >&2
    exit 1
  fi
fi

backup_file="$(cd "$(dirname "${backup_file}")" && pwd)/$(basename "${backup_file}")"

if ! docker compose version > /dev/null 2>&1; then
  echo "Error: docker compose is not available" >&2
  exit 1
fi

echo "[restore] Using backup: ${backup_file}"
echo "[restore] Starting postgres service..."
docker compose up -d postgres > /dev/null

echo "[restore] Waiting for postgres readiness..."
ready="false"
for _ in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d postgres > /dev/null 2>&1; then
    ready="true"
    break
  fi
  sleep 2
done

if [[ "${ready}" != "true" ]]; then
  echo "Error: postgres is not ready after 60 seconds" >&2
  exit 1
fi

if [[ "${reset_db}" == "true" ]]; then
  echo "[restore] Resetting database '${POSTGRES_DB}'..."
  docker compose exec -T postgres psql \
    -v ON_ERROR_STOP=1 \
    -U "${POSTGRES_USER}" \
    -d postgres \
    --set=target_db="${POSTGRES_DB}" <<'SQL'
DROP DATABASE IF EXISTS :"target_db" WITH (FORCE);
CREATE DATABASE :"target_db";
SQL
else
  echo "[restore] Restoring without database reset (--no-reset)."
fi

echo "[restore] Restoring data..."
filter_psql_restrict() {
  # Some dumps may contain psql metacommands unsupported by older psql clients.
  # They are safe to strip for restore in trusted environments.
  sed -e '/^\\restrict /d' -e '/^\\unrestrict /d'
}

if [[ "${backup_file}" == *.gz ]]; then
  gzip -dc "${backup_file}" | filter_psql_restrict | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
else
  cat "${backup_file}" | filter_psql_restrict | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
fi

echo "[restore] Restore completed successfully."
