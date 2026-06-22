package db

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/log"
)

type DB struct {
	Pool *pgxpool.Pool
	cfg  *config.Config
}

func Open(ctx context.Context, cfg *config.Config) (*DB, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	pool, err := pgxpool.New(ctx, cfg.ConnString())
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	return &DB{Pool: pool, cfg: cfg}, nil
}

func (db *DB) Close() {
	db.Pool.Close()
}

func (db *DB) ExecUpgrade(ctx context.Context, sql string, args ...any) error {
	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SET LOCAL samna_migrate.upgrade_mode = 'true'`); err != nil {
		tx.Rollback(ctx)
		return err
	}
	if _, err := tx.Exec(ctx, sql, args...); err != nil {
		tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}

func (db *DB) RunFile(ctx context.Context, path string, preSQL string, vars map[string]string) error {
	content, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	body := substituteVars(string(content), vars)

	noiseLevel := "warning"
	if log.Level >= log.LevelExtreme {
		noiseLevel = "notice"
	}

	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = 0"); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "SET LOCAL check_function_bodies = false"); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "SET LOCAL client_min_messages = "+noiseLevel); err != nil {
		return err
	}
	if preSQL != "" {
		if _, err := tx.Exec(ctx, preSQL); err != nil {
			return fmt.Errorf("%s pre: %w", path, err)
		}
	}
	log.Dump("        pgx exec %s", path)
	if _, err := tx.Exec(ctx, body); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return tx.Commit(ctx)
}

func substituteVars(body string, vars map[string]string) string {
	for k, v := range vars {
		literal := "'" + strings.ReplaceAll(v, "'", "''") + "'"
		body = strings.ReplaceAll(body, ":'"+k+"'", literal)
	}
	return body
}

func (db *DB) ColumnExists(ctx context.Context, schema, table, column string) (bool, error) {
	var n int
	err := db.Pool.QueryRow(ctx, `
		SELECT 1 FROM information_schema.columns
		WHERE table_schema=$1 AND table_name=$2 AND column_name=$3`,
		schema, table, column).Scan(&n)
	if err != nil {
		return false, nil
	}
	return n == 1, nil
}
