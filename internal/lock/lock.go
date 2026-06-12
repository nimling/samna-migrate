package lock

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/nimling/samna-migrate/internal/db"
)

const FileName = "samna_migrate.lock.json"

type Entry struct {
	FilePath string `json:"file_path"`
	Sha256   string `json:"sha256"`
}

type File struct {
	GeneratedAt string  `json:"generated_at"`
	Database    string  `json:"database"`
	ToolVersion string  `json:"tool_version"`
	Files       []Entry `json:"files"`
}

func Path(dbDir string) string {
	return filepath.Join(dbDir, FileName)
}

func Read(path string) (*File, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var lf File
	if err := json.Unmarshal(b, &lf); err != nil {
		return nil, err
	}
	return &lf, nil
}

func Collect(ctx context.Context, d *db.DB) ([]Entry, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT file_path, sha256 FROM samna_migrate.file
		WHERE state = 'applied' AND removed_at IS NULL
		ORDER BY file_path`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Entry{}
	for rows.Next() {
		var e Entry
		if err := rows.Scan(&e.FilePath, &e.Sha256); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func Write(path, database, toolVersion string, entries []Entry) error {
	sort.Slice(entries, func(i, j int) bool { return entries[i].FilePath < entries[j].FilePath })
	lf := &File{
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		Database:    database,
		ToolVersion: toolVersion,
		Files:       entries,
	}
	b, err := json.MarshalIndent(lf, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

func RefreshIfPresent(ctx context.Context, d *db.DB, dbDir, database, toolVersion string) (bool, error) {
	path := Path(dbDir)
	if _, err := os.Stat(path); err != nil {
		return false, nil
	}
	entries, err := Collect(ctx, d)
	if err != nil {
		return false, err
	}
	if err := Write(path, database, toolVersion, entries); err != nil {
		return false, err
	}
	return true, nil
}
