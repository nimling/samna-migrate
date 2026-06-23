package migrate

import (
	"context"
	"strings"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/git"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/reconcile"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	reconcileKeep        bool
	reconcileImage       string
	reconcileStopOnError bool
	reconcileNoContainer bool
)

var reconcileCmd = &cobra.Command{
	Use:   "reconcile",
	Short: "Compare the local database folder against the live server in depth",
	Long: `reconcile compares the local database folder, --db-dir (default ./database),
against the live server and where it was deployed. It runs four analyses and
never lets one stop the others.

File audit compares every local .sql file against the body stored in
samna_migrate when it was applied, and classifies each file as added, dropped,
changed, or reordered. Use --stop-one-error to halt at the first difference.

Object analysis tracks every function, table, view, type, and sequence globally
across files and reports whether it moved to another file, was renamed, changed
signature, changed content, changed position, was added, or deleted, rendered as
a git style diff with file and line.

Git locate, when the folder is a git repo, shows the real git diff of each
changed file between the commit it was deployed from and the working tree.

Container comparison starts a local docker postgres, applies every local file
into it resiliently, and compares the produced objects against the live server.
Pass --no-container to skip it. The files apply with their step pre and vars
expanded from the environment, so run reconcile with the deploy env; a build
failure is reported without stopping the other analyses.`,
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

		report, err := reconcile.Audit(ctx, d, stepsCfg, dbDir, reconcileStopOnError)
		if err != nil {
			return err
		}
		reconcile.Render(report)

		objRep, err := reconcile.AnalyzeObjects(ctx, d, stepsCfg, dbDir)
		if err != nil {
			return err
		}
		reconcile.RenderObjects(objRep)

		if err := gitLocate(ctx, d, dbDir, report); err != nil {
			return err
		}

		if reconcileNoContainer {
			return nil
		}
		log.Header("container comparison: local files built and diffed against live")
		diff, err := reconcile.CompareToLive(ctx, d, cfg, stepsCfg, dbDir, cli.Version, reconcile.Options{
			Keep:  reconcileKeep,
			Image: reconcileImage,
		})
		if err != nil {
			log.Err("container comparison failed: %v", err)
			return nil
		}
		reconcile.RenderContainerDiff(diff)
		return nil
	},
}

func gitLocate(ctx context.Context, d *db.DB, dbDir string, report *reconcile.Report) error {
	if !git.IsRepo(dbDir) {
		return nil
	}
	commits, err := reconcile.DeployedCommits(ctx, d)
	if err != nil {
		return err
	}
	printed := false
	for _, f := range report.Files {
		if f.Class != reconcile.Changed {
			continue
		}
		commit := commits[f.FilePath]
		if commit == "" {
			continue
		}
		diff := git.DiffSince(dbDir, commit, f.FilePath)
		if strings.TrimSpace(diff) == "" {
			continue
		}
		if !printed {
			log.Header("git locate: file changes since the deployed commit")
			printed = true
		}
		log.Section(f.FilePath, shortSha(commit), 0)
		renderGitDiff(diff)
		for _, r := range git.Renames(dbDir, commit, f.FilePath) {
			log.Detail("      %s", r)
		}
	}
	return nil
}

func renderGitDiff(diff string) {
	for _, ln := range strings.Split(diff, "\n") {
		switch {
		case strings.HasPrefix(ln, "+++"), strings.HasPrefix(ln, "---"),
			strings.HasPrefix(ln, "diff "), strings.HasPrefix(ln, "index "):
			log.Detail("%s", ln)
		case strings.HasPrefix(ln, "@@"):
			log.DiffHunk(ln)
		case strings.HasPrefix(ln, "+"):
			log.DiffLine('+', ln[1:])
		case strings.HasPrefix(ln, "-"):
			log.DiffLine('-', ln[1:])
		default:
			log.DiffLine(' ', strings.TrimPrefix(ln, " "))
		}
	}
}

func init() {
	reconcileCmd.Flags().BoolVar(&reconcileKeep, "keep", false, "Leave the container and candidate tree in place for inspection")
	reconcileCmd.Flags().StringVar(&reconcileImage, "image", "", "Postgres docker image, defaults to the live server major version")
	reconcileCmd.Flags().BoolVar(&reconcileStopOnError, "stop-one-error", false, "Stop the file audit at the first difference instead of reporting all")
	reconcileCmd.Flags().BoolVar(&reconcileNoContainer, "no-container", false, "Skip the container comparison, run the file audit, object analysis, and git locate only")
	rootCmd.AddCommand(reconcileCmd)
}
