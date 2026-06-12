FROM golang:1.25-alpine AS smig-build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY pkg/ ./pkg/
RUN CGO_ENABLED=0 go build -o /smig ./cmd

FROM postgres:17-alpine

ARG APP_NAME=bookable
ARG PGPORT=5432

ENV POSTGRES_DB=${APP_NAME}
ENV POSTGRES_USER=${APP_NAME}
ENV POSTGRES_PASSWORD=${APP_NAME}
ENV PGPORT=${PGPORT}
ENV PGUSER=${APP_NAME}
ENV PGPASSWORD=${APP_NAME}
ENV PGDATABASE=${APP_NAME}
ENV PGSSLMODE=disable
ENV DB_DIR=/database
ENV MIGRATE_SCHEMA=/database/migrate.yml

RUN apk add --no-cache yq

COPY database/smig/ /database/
COPY --from=smig-build /smig /usr/local/bin/smig

RUN printf '#!/bin/sh\nset -e\nexport PGHOST=/var/run/postgresql\nsmig upgrade --yes --schema=/database/migrate.yml --db-dir=/database\nsmig up --schema=/database/migrate.yml --db-dir=/database\n' \
    > /docker-entrypoint-initdb.d/migrate.sh \
 && chmod +x /docker-entrypoint-initdb.d/migrate.sh
