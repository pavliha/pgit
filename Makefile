PSQL ?= psql "postgresql://postgres:pgit@localhost:5460/pgit_test"

.PHONY: up down install test test-only test-fast verify psql reset bench

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

# Every suite, one total. DUMP=/path/to/app.dump also runs the real-schema suite.
test: install
	@./test/all.sh

# One suite by name, for an inner loop: make test-only SUITE=remote
test-only: install
	@./test/all.sh $(SUITE)

# The pgTAP assertions alone — seconds rather than minutes.
test-fast: install
	@./test/run.sh

# What CI does, and what the build plan requires before any claim of green:
# an incremental install hides forward references and duplicate definitions.
verify: down up install
	@./test/all.sh

reset: down up install

bench:
	@./bench/run.sh

psql:
	$(PSQL)
