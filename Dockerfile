FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -ldflags "-X github.com/nimling/samna-migrate/pkg/cli.Version=${VERSION}" -o /out/smig ./cmd

FROM alpine:3.20
RUN apk add --no-cache postgresql-client
COPY --from=build /out/smig /usr/local/bin/smig
ENTRYPOINT ["/usr/local/bin/smig"]
