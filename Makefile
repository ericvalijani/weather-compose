.PHONY: up down logs build restart ps psql redis-cli grafana prom

up:
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f --tail=100

build:
	docker compose build

restart:
	docker compose restart

ps:
	docker compose ps

psql:
	docker compose exec postgres sh -c 'psql -U $$POSTGRES_USER -d $$POSTGRES_DB'

redis-cli:
	docker compose exec redis redis-cli

grafana:
	@echo Grafana:   http://localhost:3000

prom:
	@echo Prometheus: http://localhost:9090

