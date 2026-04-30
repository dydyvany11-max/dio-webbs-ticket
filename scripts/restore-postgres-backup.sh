#!/usr/bin/env bash
set -Eeuo pipefail

# Быстрые команды (запускать из корня проекта):
# 1) Поднять сервисы:
#    docker compose up -d postgres postgres-backup
#
# 2) Подготовить тестовые данные:
#    docker compose exec -T postgres psql -U diocontickets -d diocontickets_db -c "CREATE TABLE IF NOT EXISTS public.backup_smoke(id int primary key, note text); INSERT INTO public.backup_smoke(id,note) VALUES (1,'before_backup') ON CONFLICT (id) DO UPDATE SET note=EXCLUDED.note;"
#
# 3) Создать бэкап вручную:
#    docker compose run --rm postgres-backup /backup.sh
#
# 4) Изменить данные (для проверки восстановления):
#    docker compose exec -T postgres psql -U diocontickets -d diocontickets_db -c "UPDATE public.backup_smoke SET note='broken' WHERE id=1;"
#
# 5) Восстановить последний бэкап:
#    bash scripts/restore-postgres-backup.sh
#
# 6) Проверить результат восстановления:
#    docker compose exec -T postgres psql -U diocontickets -d diocontickets_db -c "SELECT * FROM public.backup_smoke;"
#
usage() {
  cat <<'EOF'
Использование:
  bash scripts/restore-postgres-backup.sh [--file <path>] [--no-reset]
  bash scripts/restore-postgres-backup.sh [<path-to-backup>]

Описание:
  Восстанавливает PostgreSQL из бэкапа .sql или .sql.gz через docker compose.
  По умолчанию перед восстановлением целевая база пересоздаётся.

Опции:
  --file <path>  Путь к файлу бэкапа (.sql или .sql.gz).
  --no-reset     Не удалять/создавать базу перед восстановлением.
  -h, --help     Показать эту справку.

Примеры:
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
      [[ $# -ge 2 ]] || { echo "Ошибка: для --file нужно указать значение" >&2; exit 1; }
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
      echo "Ошибка: неизвестная опция '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "${backup_file}" ]]; then
        echo "Ошибка: файл бэкапа уже указан: '${backup_file}'" >&2
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

: "${POSTGRES_USER:?POSTGRES_USER не задан. Добавьте его в .env}"
: "${POSTGRES_DB:?POSTGRES_DB не задан. Добавьте его в .env}"

if [[ -z "${backup_file}" ]]; then
  if [[ ! -d "${BACKUPS_DIR}" ]]; then
    echo "Ошибка: директория бэкапов не найдена: ${BACKUPS_DIR}" >&2
    exit 1
  fi

  backup_file="$(find "${BACKUPS_DIR}" -type f \( -name '*.sql.gz' -o -name '*.sql' \) | sort | tail -n 1)"
  if [[ -z "${backup_file}" ]]; then
    echo "Ошибка: в ${BACKUPS_DIR} не найдено файлов бэкапа" >&2
    exit 1
  fi
fi

if [[ ! -f "${backup_file}" ]]; then
  if [[ -f "${PROJECT_ROOT}/${backup_file}" ]]; then
    backup_file="${PROJECT_ROOT}/${backup_file}"
  else
    echo "Ошибка: файл бэкапа не найден: ${backup_file}" >&2
    exit 1
  fi
fi

backup_file="$(cd "$(dirname "${backup_file}")" && pwd)/$(basename "${backup_file}")"

if ! docker compose version > /dev/null 2>&1; then
  echo "Ошибка: docker compose недоступен" >&2
  exit 1
fi

echo "[restore] Используется бэкап: ${backup_file}"
echo "[restore] Запуск сервиса postgres..."
docker compose up -d postgres > /dev/null

echo "[restore] Ожидание готовности postgres..."
ready="false"
for _ in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d postgres > /dev/null 2>&1; then
    ready="true"
    break
  fi
  sleep 2
done

if [[ "${ready}" != "true" ]]; then
  echo "Ошибка: postgres не готов спустя 60 секунд" >&2
  exit 1
fi

if [[ "${reset_db}" == "true" ]]; then
  echo "[restore] Пересоздание базы '${POSTGRES_DB}'..."
  docker compose exec -T postgres psql \
    -v ON_ERROR_STOP=1 \
    -U "${POSTGRES_USER}" \
    -d postgres \
    --set=target_db="${POSTGRES_DB}" <<'SQL'
DROP DATABASE IF EXISTS :"target_db" WITH (FORCE);
CREATE DATABASE :"target_db";
SQL
else
  echo "[restore] Восстановление без пересоздания базы (--no-reset)."
fi

echo "[restore] Восстановление данных..."
filter_psql_restrict() {
  # В некоторых дампах встречаются psql-метакоманды, которые не понимают старые psql-клиенты.
  # Для восстановления в доверенной среде их можно безопасно удалить из потока.
  sed -e '/^\\restrict /d' -e '/^\\unrestrict /d'
}

if [[ "${backup_file}" == *.gz ]]; then
  gzip -dc "${backup_file}" | filter_psql_restrict | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
else
  cat "${backup_file}" | filter_psql_restrict | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
fi

echo "[restore] Восстановление завершено успешно."
