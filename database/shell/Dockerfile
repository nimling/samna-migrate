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
ENV DB_DIR=/database

RUN apk add --no-cache yq

COPY . /database/
RUN printf '#!/bin/sh\n/database/scripts/migrate.sh --schema=/database/migrate.yml up\n' > /docker-entrypoint-initdb.d/migrate.sh && chmod +x /docker-entrypoint-initdb.d/migrate.sh
