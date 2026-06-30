package lint

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/nimling/samna-migrate/internal/hash"
	"github.com/nimling/samna-migrate/internal/lock"
	"github.com/nimling/samna-migrate/internal/steps"
)

type Finding struct {
	File    string
	Level   string
	Message string
}

type Result struct {
	Findings []Finding
	Errors   int
	Warnings int
}

func (r *Result) add(file, level, message string) {
	r.Findings = append(r.Findings, Finding{File: file, Level: level, Message: message})
	if level == "error" {
		r.Errors++
	} else {
		r.Warnings++
	}
}

var (
	rxReplicationRole = regexp.MustCompile(`(?i)session_replication_role`)
	rxCommentFn       = regexp.MustCompile(`(?i)COMMENT\s+ON\s+FUNCTION\s+[a-z0-9_."]+\s+IS`)
	rxCreateType      = regexp.MustCompile(`(?i)CREATE\s+TYPE\b`)
	rxCreateIndex     = regexp.MustCompile(`(?i)CREATE\s+(?:UNIQUE\s+)?INDEX(?:\s+CONCURRENTLY)?\s+(IF\s+NOT\s+EXISTS\s+)?`)
	rxAddColumn       = regexp.MustCompile(`(?i)ADD\s+COLUMN\s+(IF\s+NOT\s+EXISTS\s+)?`)
	rxCreateFunction  = regexp.MustCompile(`(?i)CREATE\s+(OR\s+REPLACE\s+)?FUNCTION`)
	rxPgTypeGuard     = regexp.MustCompile(`(?i)pg_type`)
	rxDupObjectGuard  = regexp.MustCompile(`(?i)duplicate_object`)
)

func Run(stepsCfg *steps.Config, dbDir, lockPath string) (*Result, error) {
	r := &Result{}

	validSlugs := stepsCfg.Slugs()
	onDisk := map[string]string{}
	for _, st := range stepsCfg.Steps {
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			if _, slug, _, ok := steps.ParseFilename(f.Name); !ok {
				r.add(f.Rel, "error", "filename grammar must be V<version>__<slug>_<name>.sql with version >= 1")
			} else if !validSlugs[slug] {
				r.add(f.Rel, "error", fmt.Sprintf("filename slug %q is not a slug declared by any step in migrate.yml", slug))
			}
			b, err := os.ReadFile(f.AbsPath)
			if err != nil {
				return nil, fmt.Errorf("read %s: %w", f.Rel, err)
			}
			content := string(b)
			checkContent(r, f.Rel, st.Type, content)
			sha, err := hash.File(f.AbsPath)
			if err != nil {
				return nil, err
			}
			onDisk[f.Rel] = sha
		}
	}

	if lockPath != "" {
		lf, err := lock.Read(lockPath)
		if err == nil {
			for _, e := range lf.Files {
				sha, ok := onDisk[e.FilePath]
				if !ok {
					r.add(e.FilePath, "error", "locked file is missing on disk. Restore it or rebuild the lockfile with smig lock")
					continue
				}
				if sha != e.Sha256 {
					r.add(e.FilePath, "error", "locked file modified after apply. Use smig rebase, never edit in place")
				}
			}
		}
	}

	return r, nil
}

func checkContent(r *Result, rel, stepType, content string) {
	if rxReplicationRole.MatchString(content) {
		r.add(rel, "error", "session_replication_role is forbidden, triggers are the contract")
	}
	for _, m := range rxCommentFn.FindAllString(content, -1) {
		if !strings.Contains(m, "(") {
			r.add(rel, "error", "COMMENT ON FUNCTION without an argument signature breaks once an overload exists. Qualify as name(args)")
			break
		}
	}
	if rxCreateType.MatchString(content) && !rxPgTypeGuard.MatchString(content) && !rxDupObjectGuard.MatchString(content) {
		r.add(rel, "warn", "CREATE TYPE without a pg_type or duplicate_object guard fails on reapply")
	}
	if stepType != "migration" {
		return
	}
	for _, m := range rxCreateIndex.FindAllStringSubmatch(content, -1) {
		if m[1] == "" {
			r.add(rel, "warn", "CREATE INDEX without IF NOT EXISTS is not idempotent")
			break
		}
	}
	for _, m := range rxAddColumn.FindAllStringSubmatch(content, -1) {
		if m[1] == "" {
			r.add(rel, "warn", "ADD COLUMN without IF NOT EXISTS is not idempotent")
			break
		}
	}
	for _, m := range rxCreateFunction.FindAllStringSubmatch(content, -1) {
		if m[1] == "" {
			r.add(rel, "warn", "CREATE FUNCTION without OR REPLACE is not idempotent")
			break
		}
	}
}
