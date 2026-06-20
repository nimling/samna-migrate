package verify

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/lint"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/preflight"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/internal/upgrade"
)

type Options struct {
	DryRun bool
	Keep   bool
	Image  string
}

func Run(ctx context.Context, live *db.DB, cfg *config.Config, stepsCfg *steps.Config, dbDir, toolVersion string, opts Options) error {
	upgradedDir := filepath.Join(filepath.Dir(cfg.StepsFile), ".upgraded")
	if !hasContent(upgradedDir) {
		return fmt.Errorf(".upgraded/ is missing or empty. Run smig merge first")
	}

	log.Header("materialize candidate tree")
	candidateDir, candSteps, err := materializeCandidate(stepsCfg, cfg.StepsFile, dbDir, upgradedDir)
	if err != nil {
		return err
	}
	if !opts.Keep {
		defer os.RemoveAll(candidateDir)
	}
	log.Success("candidate at %s", candidateDir)

	candStepsCfg, err := steps.Load(candSteps)
	if err != nil {
		return err
	}

	log.Header("lint candidate tree")
	lr, err := lint.Run(candStepsCfg, candidateDir, "")
	if err != nil {
		return err
	}
	for _, f := range lr.Findings {
		if f.Level == "error" {
			log.Err("  %s  %s", f.File, f.Message)
		} else {
			log.Warn("  %s  %s", f.File, f.Message)
		}
	}
	if lr.Errors > 0 {
		return fmt.Errorf("candidate tree failed lint with %d errors, fix and rerun smig merge", lr.Errors)
	}
	log.Success("lint clean, %d warnings", lr.Warnings)

	image := opts.Image
	if image == "" {
		image = imageForServer(ctx, live)
	}

	log.Header("start disposable postgres " + image)
	cont, cand, err := startContainer(ctx, cfg, image)
	if err != nil {
		return err
	}
	defer cand.Close()
	if !opts.Keep {
		defer stopContainer(cont.Name)
	}
	log.Success("container %s on port %d", cont.Name, cont.Port)

	verdicts := Verdicts{}

	log.Header("verdict bootstrap: fresh database from candidate tree")
	if err := bootstrapCandidate(ctx, cand, cont.Cfg, candStepsCfg, candSteps, candidateDir, toolVersion); err != nil {
		log.Err("bootstrap failed: %v", err)
	} else {
		verdicts.Bootstrap = true
		log.Success("bootstrap clean")
	}

	var candInv map[string]string
	if verdicts.Bootstrap {
		log.Header("verdict equality: candidate against live")
		schemas := schemaUnion(stepsCfg)
		liveInv, err := Inventory(ctx, live, schemas)
		if err != nil {
			return err
		}
		candInv, err = Inventory(ctx, cand, schemas)
		if err != nil {
			return err
		}
		diff := CompareInventories(liveInv, candInv)
		if diff.Empty() {
			verdicts.Equality = true
			log.Success("equality clean: %d objects match", len(liveInv))
		} else {
			reportDiff(diff)
		}

		log.Header("verdict determinism: second clean bootstrap matches the first")
		cont2, cand2, err := startContainer(ctx, cfg, image)
		if err != nil {
			return err
		}
		defer cand2.Close()
		if !opts.Keep {
			defer stopContainer(cont2.Name)
		}
		if err := bootstrapCandidate(ctx, cand2, cont2.Cfg, candStepsCfg, candSteps, candidateDir, toolVersion); err != nil {
			log.Err("second bootstrap failed: %v", err)
		} else {
			cand2Inv, err := Inventory(ctx, cand2, schemas)
			if err != nil {
				return err
			}
			diff2 := CompareInventories(candInv, cand2Inv)
			if diff2.Empty() {
				verdicts.Determinism = true
				log.Success("determinism clean: two independent bootstraps match")
			} else {
				log.Err("two bootstraps of the same tree diverged")
				reportDiff(diff2)
			}
		}
	} else {
		log.Warn("equality and determinism skipped, bootstrap failed")
	}

	log.Header("verdicts")
	logVerdict("bootstrap", verdicts.Bootstrap)
	logVerdict("equality", verdicts.Equality)
	logVerdict("determinism", verdicts.Determinism)

	if opts.Keep {
		log.Plain("container kept: %s on port %d, candidate tree at %s", cont.Name, cont.Port, candidateDir)
	}

	allPassed := verdicts.Bootstrap && verdicts.Equality && verdicts.Determinism
	if !allPassed {
		return fmt.Errorf("verify failed")
	}
	if opts.DryRun {
		log.Info("dry run: proof manifest not written")
		return nil
	}

	sha, err := TreeSha(upgradedDir)
	if err != nil {
		return err
	}
	m := &Manifest{
		UpgradedSha:    sha,
		VerifiedAt:     time.Now().UTC().Format(time.RFC3339),
		ToolVersion:    toolVersion,
		SourceDatabase: cfg.PGDatabase,
		Image:          image,
		Verdicts:       verdicts,
	}
	if err := WriteManifest(upgradedDir, m); err != nil {
		return err
	}
	log.Success("proof written to %s", filepath.Join(upgradedDir, manifestName))
	log.Info("smig merge --apply now accepts this .upgraded/ tree")
	return nil
}

func bootstrapCandidate(ctx context.Context, cand *db.DB, candCfg *config.Config, candStepsCfg *steps.Config, candSteps, candidateDir, toolVersion string) error {
	if err := schema.Ensure(ctx, cand); err != nil {
		return err
	}
	if err := upgrade.Chain(ctx, cand, toolVersion); err != nil {
		return err
	}
	snap, err := schema.Snapshot(ctx, cand, candSteps)
	if err != nil {
		return err
	}
	if err := schema.WriteYAMLSha(ctx, cand, snap.DiskYAMLSha, toolVersion); err != nil {
		return err
	}
	if _, err := preflight.Scan(ctx, cand, snap, candStepsCfg, candidateDir); err != nil {
		return err
	}
	pendings, err := apply.ListPending(ctx, cand)
	if err != nil {
		return err
	}
	log.Info("%d files to apply", len(pendings))
	for _, p := range pendings {
		st, _ := apply.FileRel(candStepsCfg, p.FilePath, candidateDir)
		log.Plain("  %s", p.FilePath)
		if err := apply.File(ctx, cand, p, st, candidateDir, toolVersion, candCfg.PGUser, candCfg.PGHost, candCfg.PGDatabase); err != nil {
			return fmt.Errorf("%s: %w", p.FilePath, err)
		}
	}
	return nil
}

func schemaUnion(stepsCfg *steps.Config) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, st := range stepsCfg.Steps {
		for _, s := range st.Schemas {
			if s == "samna_migrate" || seen[s] {
				continue
			}
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func logVerdict(name string, passed bool) {
	if passed {
		log.Success("  %s  pass", name)
	} else {
		log.Err("  %s  fail", name)
	}
}
