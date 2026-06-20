package db

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nimling/samna-migrate/internal/config"
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

func (db *DB) RunPsqlFile(ctx context.Context, path string, preSQL string, vars map[string]string) error {
	args := []string{"--quiet", "--single-transaction", "--set", "ON_ERROR_STOP=1"}
	if db.cfg.PGHost != "" {
		args = append(args, "--host", db.cfg.PGHost)
	}
	if db.cfg.PGPort != "" {
		args = append(args, "--port", db.cfg.PGPort)
	}
	args = append(args, "--username", db.cfg.PGUser, "--dbname", db.cfg.PGDatabase)
	keys := make([]string, 0, len(vars))
	for k := range vars {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		args = append(args, "-v", k+"="+vars[k])
	}
	args = append(args, "-c", "SET check_function_bodies = false")
	if preSQL != "" {
		args = append(args, "-c", preSQL)
	}
	args = append(args, "-f", path)
	cmd := exec.CommandContext(ctx, "psql", args...)
	cmd.Env = append(os.Environ(), "PGPASSWORD="+db.cfg.PGPassword)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
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
