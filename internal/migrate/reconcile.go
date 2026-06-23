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
	reconcileNoContainer bool
	reconcileJSON        bool
)

var reconcileCmd = &cobra.Command{
	Use:   "reconcile",
	Short: "Compare the local database folder against the live server in depth",
	Long: `reconcile compares the local database folder, --db-dir (default ./database),
against the live server and where it was deployed, and produces one joint diff.

It runs four analyses and never lets one stop the others: the file audit (each
local .sql against the body stored at apply time), the object analysis (every
function, table, view, type, and sequence tracked globally for moves, renames,
signature, content, and position changes), the git locate (the real git diff of
each changed file since the commit it was deployed from, when the folder is a git
repo), and the container comparison (build every local file into a fresh docker
postgres and diff the produced objects against the live server).

The results are merged into a single report keyed by object. Each entry carries
the remediation direction (create, drop, or update on live), the live signature,
the desired SQL, and the current live DDL, so the diff is enough to write the SQL
that closes the gap. Pass --json to emit the full structured report.

Pass --no-container to skip the docker phase. The container build applies files
with their step pre and vars expanded from the environment, so run reconcile with
the deploy env; a build failure is reported without stopping the other analyses.`,
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
		if !reconcileNoContainer {
			if !reconcile.DockerPresent() {
				log.Err("docker is required for the container comparison. install docker or pass --no-container")
			} else {
				cdiff, err = reconcile.CompareToLive(ctx, d, cfg, stepsCfg, dbDir, cli.Version, reconcile.Options{
					Keep:  reconcileKeep,
					Image: reconcileImage,
				})
				if err != nil {
					log.Err("container comparison failed: %v", err)
					cdiff = nil
				}
			}
		}

		joint := reconcile.BuildJoint(cfg.PGDatabase+"@"+hostOrLocalhost(cfg), audit, objRep, cdiff, commits, dbDir)
		if reconcileJSON {
			return reconcile.WriteJSON(os.Stdout, joint)
		}
		reconcile.RenderJoint(joint)
		return nil
	},
}

func init() {
	reconcileCmd.Flags().BoolVar(&reconcileKeep, "keep", false, "Leave the container and candidate tree in place for inspection")
	reconcileCmd.Flags().StringVar(&reconcileImage, "image", "", "Postgres docker image, defaults to the live server major version")
	reconcileCmd.Flags().BoolVar(&reconcileStopOnError, "stop-one-error", false, "Stop the file audit at the first difference instead of reporting all")
	reconcileCmd.Flags().BoolVar(&reconcileNoContainer, "no-container", false, "Skip the container comparison, run the file audit, object analysis, and git locate only")
	reconcileCmd.Flags().BoolVar(&reconcileJSON, "json", false, "Emit the full joint report as JSON for use in another session")
	rootCmd.AddCommand(reconcileCmd)
}
