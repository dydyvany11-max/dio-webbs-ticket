# Monitoring

## Состав мониторинга

- `prometheus` (`:9090`) - сбор метрик и расчет алертов
- `alertmanager` (`:9093`) - маршрутизация и отправка уведомлений
- `grafana` (`:3001`) - дашборды
- `postgres-exporter` (`:9187`) - метрики PostgreSQL
- `redis-exporter` (`:9121`) - метрики Redis
- `backup-exporter` (`:9105`) - свежесть бэкапов PostgreSQL

## Запуск

Из корня проекта:

```bash
docker compose up -d
```

Проверить, что все мониторинг-сервисы запущены:

```bash
docker compose ps prometheus grafana alertmanager postgres-exporter redis-exporter backup-exporter
```

## Проверка, что метрики собираются

1. Откройте `http://localhost:9090/targets`
2. Все нужные таргеты должны быть `UP`
3. Если какой-то `DOWN`, проверьте его контейнер:

```bash
docker compose logs --tail=100 <service_name>
```

## Проверка алертов

Правила лежат в `monitoring/prometheus/alerts.yml`.

Проверка в UI:

1. `http://localhost:9090/alerts`
2. `State = Firing` - активный алерт
3. `State = Inactive` - всё ок

Проверка в Alertmanager:

1. `http://localhost:9093`
2. Вкладка Alerts показывает активные группы

## Пример теста алерта PostgreSQL

1. Остановить PostgreSQL:

```bash
docker compose stop postgres
```

2. Подождать 2-3 минуты (`for: 2m` в правиле)
3. Убедиться, что `PostgresServiceDown` стал `firing`
4. Вернуть PostgreSQL:

```bash
docker compose start postgres
```

5. Подождать 1-2 минуты и проверить, что алерт перешел в `resolved/inactive`

## Настройка email в Alertmanager

Файл: `monitoring/alertmanager/alertmanager.yml`

Минимально нужно задать:

- `smtp_smarthost` - SMTP сервер (`host:port`)
- `smtp_from` - адрес отправителя
- `receivers[].email_configs[].to` - адрес получателя

После изменения конфигурации перезапустите:

```bash
docker compose restart alertmanager prometheus
```

## Grafana

- URL: `http://localhost:3001`
- логин/пароль по умолчанию: `admin` / `admin`
- datasource Prometheus уже подключается через provisioning

Если дашборды пустые:

1. Проверьте datasource `Prometheus` в Grafana
2. Проверьте `UP` целей в `Prometheus /targets`
3. Проверьте time range (например, `Last 15 minutes`)

## Логи (ELK)

- Kibana: `http://localhost:5601`
- Индекс логов backend: `backend-logs-*`
- Data View в Kibana: pattern `backend-logs-*`, time field `@timestamp`

Для поиска ошибок используйте KQL:

```text
app.level : "ERROR"
```

