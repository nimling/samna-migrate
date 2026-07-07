package migrate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/hash"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/preflight"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var runInteractive bool

var runCmd = &cobra.Command{
	Use:   "run [target]",
	Short: "Run a single step or SQL file from migrate.yml",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if envFile != "" {
			if err := config.LoadDotEnv(envFile); err != nil {
				return err
			}
		}
		cfg := config.FromEnv()
		cfg.StepsFile = stepsFile
		cfg.DBDir = dbDir
		d, err := db.Open(ctx, cfg)
		if err != nil {
			return err
		}
		defer d.Close()
		if err := bootCheck(ctx, d, stepsFile, dbDir, cli.Version); err != nil {
			return err
		}
		stepsCfg, err := steps.Load(stepsFile)
		if err != nil {
			return err
		}
		snap, err := schema.Snapshot(ctx, d, stepsFile)
		if err != nil {
			return err
		}

		log.Header(fmt.Sprintf("migrate run: %s", cfg.PGDatabase))
		if _, err := preflight.Scan(ctx, d, snap, stepsCfg, dbDir); err != nil {
			return err
		}

		files, err := apply.ListFiles(ctx, d)
		if err != nil {
			return err
		}
		if len(files) == 0 {
			log.Success("no registered files")
			return nil
		}

		groups, err := groupPending(files, stepsCfg, dbDir)
		if err != nil {
			return err
		}
		ordered := flatten(groups)

		target := ""
		if len(args) == 1 {
			target = args[0]
		}

		executedBy := cfg.PGUser
		host := cfg.PGHost
		if host == "" {
			host = "localhost"
		}

		var idxs []int
		extAbs := ""
		if runInteractive && target == "" {
			sel, tok, perr := promptRun(os.Stdin, ordered)
			if perr != nil {
				return perr
			}
			idxs, target = sel, tok
		} else {
			sel, rerr := selectTargets(target, ordered)
			if rerr == nil {
				idxs = sel
			} else {
				abs, ok := resolvePath(target, dbDir, stepsFile)
				if !ok {
					return rerr
				}
				for i, o := range ordered {
					oAbs, aerr := filepath.Abs(filepath.Join(dbDir, o.p.FilePath))
					if aerr == nil && oAbs == abs {
						idxs = []int{i}
						break
					}
				}
				if len(idxs) == 0 {
					if !force {
						return fmt.Errorf("external SQL %s requires --force", abs)
					}
					extAbs = abs
				}
			}
		}

		if extAbs != "" {
			return runExternal(ctx, d, extAbs, dbDir, cfg.PGDatabase, executedBy, host)
		}

		rightEdge := 0
		for _, g := range groups {
			if w := 2 + len(g.name) + 2 + len(fmt.Sprintf("%d file(s)", len(g.files))); w > rightEdge {
				rightEdge = w
			}
		}
		for _, o := range ordered {
			if w := 4 + len(o.p.FileName) + 2 + durWidth; w > rightEdge {
				rightEdge = w
			}
		}

		ran := 0
		start := time.Now()
		var cur *pendingGroup
		for _, i := range idxs {
			o := ordered[i]
			if o.g != cur {
				cur = o.g
				log.Section(o.g.name, fmt.Sprintf("%d file(s)", len(idxs)), rightEdge)
				logStepInternals(o.g.st)
			}
			fileStart := time.Now()
			if err := apply.File(ctx, d, o.p, o.g.st, dbDir, cli.Version, executedBy, host, cfg.PGDatabase, false); err != nil {
				return fmt.Errorf("%s failed: %w", o.p.FilePath, err)
			}
			log.Step(o.p.FileName, time.Since(fileStart).Round(time.Millisecond).String(), rightEdge)
			log.Detail("      sha %s  size %dB  pos %d", shortSha(o.p.Sha), o.p.Size, o.p.Position)
			ran++
		}
		log.Plain("")
		log.Success("ran %d file(s) in %s", ran, time.Since(start).Round(time.Millisecond))
		return nil
	},
}

func resolvePath(target, dbDir, stepsFile string) (string, bool) {
	if filepath.IsAbs(target) {
		if fileExists(target) {
			return target, true
		}
		return "", false
	}
	for _, base := range []string{dbDir, filepath.Dir(stepsFile), "."} {
		cand := filepath.Join(base, target)
		if fileExists(cand) {
			if abs, err := filepath.Abs(cand); err == nil {
				return abs, true
			}
		}
	}
	return "", false
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

func runExternal(ctx context.Context, d *db.DB, abs, dbDir, database, executedBy, host string) error {
	sha, err := hash.File(abs)
	if err != nil {
		return err
	}
	size, err := hash.Size(abs)
	if err != nil {
		return err
	}
	base := filepath.Base(abs)
	ep := apply.Pending{FileName: base, FilePath: abs, Sha: sha, Size: size}
	rightEdge := 4 + len(base) + 2 + durWidth
	log.Section("External", "1 file(s)", rightEdge)
	start := time.Now()
	if err := apply.File(ctx, d, ep, nil, dbDir, cli.Version, executedBy, host, database, true); err != nil {
		return fmt.Errorf("%s failed: %w", abs, err)
	}
	log.Step(base, time.Since(start).Round(time.Millisecond).String(), rightEdge)
	log.Detail("      sha %s  size %dB  external", shortSha(sha), size)
	log.Plain("")
	log.Success("ran 1 external file in %s", time.Since(start).Round(time.Millisecond))
	return nil
}
