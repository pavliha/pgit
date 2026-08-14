PSQL ?= psql "postgresql://postgres:pgit@localhost:5460/pgit_test"

.PHONY: up down install test psql reset bench

up:
	docker compose up -d --build --wait
	@for i in $$(seq 1 60); do \
	  $(PSQL) -q -c "SELECT 1" >/dev/null 2>&1 && exit 0; \
	  sleep 1; \
	done; \
	echo "database never became ready"; exit 1

down:
	docker compose down -v

install:
	$(PSQL) -v ON_ERROR_STOP=1 -q -f sql/install.sql
	$(PSQL) -v ON_ERROR_STOP=1 -q -c "CREATE EXTENSION IF NOT EXISTS pgtap"

test: install
	@./test/run.sh
	@./test/cli_test.sh
	@./test/kill_test.sh
	@./test/rds_test.sh

reset: down up install

bench:
	@./bench/run.sh

psql:
	$(PSQL)
