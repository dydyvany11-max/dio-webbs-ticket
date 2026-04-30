# diocon-tickets

## Что поднимается через Docker Compose

Один `docker compose up -d` поднимает:

- инфраструктуру приложения: `postgres`, `redis`, `maildev`, `minio`, `languagetool`
- бэкапы БД: `postgres-backup`, `backup-exporter`
- мониторинг: `prometheus`, `grafana`, `alertmanager`, `postgres-exporter`, `redis-exporter`
- логи (ELK): `elasticsearch`, `kibana`, `logstash`, `filebeat`

## Быстрый старт

1. Скопируйте переменные окружения:

```bash
cp .env.example .env
```

2. Запустите весь стек:

```bash
docker compose up -d
```

3. Проверьте статус контейнеров:

```bash
docker compose ps
```

## Основные адреса

- Backend: `http://localhost:8000`
- Prometheus: `http://localhost:9090`
- Alertmanager: `http://localhost:9093`
- Grafana: `http://localhost:3001`
- Elasticsearch: `http://localhost:9200`
- Kibana: `http://localhost:5601`

## Мониторинг: что для чего

- `prometheus`: собирает метрики со всех целей (`/metrics`, exporter-ы), считает правила алертов
- `alertmanager`: принимает алерты от Prometheus и отправляет уведомления (например, на email)
- `grafana`: дашборды и графики по метрикам Prometheus
- `postgres-exporter`: превращает состояние PostgreSQL в метрики (`pg_up`, размеры, счетчики)
- `redis-exporter`: метрики Redis (`redis_up`, клиенты, память и т.д.)
- `backup-exporter`: проверяет свежесть бэкапа PostgreSQL (`postgres_backup_fresh`)
- `elasticsearch + logstash + filebeat + kibana`: сбор, хранение и просмотр логов backend

Подробная инструкция по мониторингу: [monitoring/README.md](monitoring/README.md)

## Бэкапы PostgreSQL

Бэкапы создаёт контейнер `postgres-backup` по расписанию (`POSTGRES_BACKUP_SCHEDULE`, по умолчанию `@weekly`).

Файлы лежат в:

- `backups/postgres/daily`
- `backups/postgres/weekly`
- `backups/postgres/monthly`
- `backups/postgres/last`

## Восстановление бэкапа одной командой

Из корня проекта:

```bash
./restore-db.sh
```

С конкретным файлом:

```bash
./restore-db.sh --file backups/postgres/last/diocontickets_db-latest.sql.gz
```

Без пересоздания базы:

```bash
./restore-db.sh --no-reset
```

Если нет прав на запуск:

```bash
chmod +x ./restore-db.sh ./scripts/restore-postgres-backup.sh
```

## Проверка backup/restore (smoke test)

1. Запустить сервисы БД и бэкапа:

```bash
docker compose up -d postgres postgres-backup
```

2. Записать тестовые данные:

```bash
docker compose exec -T postgres psql -U diocontickets -d diocontickets_db -c "CREATE TABLE IF NOT EXISTS public.backup_smoke(id int primary key, note text); INSERT INTO public.backup_smoke(id,note) VALUES (1,'before_backup') ON CONFLICT (id) DO UPDATE SET note=EXCLUDED.note;"
```

3. Сделать бэкап вручную:

```bash
docker compose run --rm postgres-backup /backup.sh
```

4. Испортить данные:

```bash
docker compose exec -T postgres psql -U diocontickets -d diocontickets_db -c "UPDATE public.backup_smoke SET note='broken' WHERE id=1;"
```

5. Восстановить:

```bash
./restore-db.sh
```

6. Проверить:

```bash
docker compose exec -T postgres psql -U diocontickets -d diocontickets_db -c "SELECT * FROM public.backup_smoke;"
```

Если значение `note = before_backup`, восстановление прошло успешно.

