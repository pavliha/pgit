ARG PG=18
FROM postgres:${PG}
ARG PG

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-${PG}-pgtap \
 && rm -rf /var/lib/apt/lists/*
