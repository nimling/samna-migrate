package migrate

import (
	"os"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
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
	reconcileJSON        bool
	reconcileFiles       bool
	reconcileObjects     bool
	reconcileGit         bool
	reconcileDb          bool
)

var reconcileCmd = &cobra.Command{
	Use:   "reconcile",
	Short: "Compare the local database folder against the live server in depth",
	Long: `reconcile fuses four ways of finding drift and renders everything that
differs in a git-diff look. The two axes are independent.

Section flags select which approaches run and render, each collecting the maximum
it can. With none of them set, all four run, the joint:

  --files     each local .sql against the body stored at apply time
  --objects   every created object tracked globally for moves, renames, signature,
              content, and position changes
  --git       the real git diff of each changed, dropped, or reordered file since
              the commit it was deployed from, when the folder is a git repo
  --db        build every local file into a fresh docker postgres and diff the
              produced objects against the live server, across every kind: functions,
              tables and columns, constraints, indexes, triggers, views, types,
              sequences, grants, and comments

--json is the output format, orthogonal to the section flags. Bare --json emits the
joint as machine data; --db --json emits only the database comparison. Each object
carries the remediation direction, the current live DDL, the desired SQL, and an
apply phase, so the report is enough to write the SQL that makes two servers match.

The --db build applies files with their step pre and vars expanded from the
environment, so run reconcile with the deploy env; a build failure is reported
without stopping the other approaches, and only-in-live verdicts are downgraded to
review while the build is incomplete.`,
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

		sel := reconcile.Sections{Files: reconcileFiles, Objects: reconcileObjects, Git: reconcileGit, Db: reconcileDb}
		if !sel.Files && !sel.Objects && !sel.Git && !sel.Db {
			sel = reconcile.Sections{Files: true, Objects: true, Git: true, Db: true}
		}

		if reconcileJSON {
			log.Level = log.LevelSilent
		}

		audit, err := reconcile.Audit(ctx, d, stepsCfg, dbDir, reconcileStopOnError)
		if err != nil {
			return err
		}
		objRep, err := reconcile.AnalyzeObjects(ctx, d, stepsCfg, dbDir)
		if err != nil {
			return err
		}
		commits, err := reconcile.DeployedCommits(ctx, d)
		if err != nil {
			return err
		}

		var cdiff *reconcile.ContainerDiff
		if sel.Db {
			if !reconcile.DockerPresent() {
				log.Err("docker is required for the --db comparison. install docker or drop --db")
			} else {
				cdiff, err = reconcile.CompareToLive(ctx, d, cfg, stepsCfg, dbDir, cli.Version, reconcile.Options{
					Keep:  reconcileKeep,
					Image: reconcileImage,
				})
				if err != nil {
					log.Err("database comparison failed: %v", err)
					cdiff = nil
				}
			}
		}

		joint := reconcile.BuildJoint(sel, cfg.PGDatabase+"@"+hostOrLocalhost(cfg), audit, objRep, cdiff, commits, dbDir)
		if reconcileJSON {
			return reconcile.WriteJSON(os.Stdout, joint)
		}
		reconcile.RenderJoint(joint)
		return nil
	},
}

func init() {
	reconcileCmd.Flags().BoolVar(&reconcileFiles, "files", false, "Render the file audit section")
	reconcileCmd.Flags().BoolVar(&reconcileObjects, "objects", false, "Render the object analysis section")
	reconcileCmd.Flags().BoolVar(&reconcileGit, "git", false, "Render the git history section")
	reconcileCmd.Flags().BoolVar(&reconcileDb, "db", false, "Render the database to database comparison section")
	reconcileCmd.Flags().BoolVar(&reconcileJSON, "json", false, "Emit the selected sections as JSON for use in another session")
	reconcileCmd.Flags().BoolVar(&reconcileKeep, "keep", false, "Leave the container and candidate tree in place for inspection")
	reconcileCmd.Flags().StringVar(&reconcileImage, "image", "", "Postgres docker image, defaults to the live server major version")
	reconcileCmd.Flags().BoolVar(&reconcileStopOnError, "stop-one-error", false, "Stop the file audit at the first difference instead of reporting all")
	rootCmd.AddCommand(reconcileCmd)
}
