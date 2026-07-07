package reconcile

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
	if hasContent(upgradedDir) {
		log.Header("materialize candidate tree from " + dbDir + " overlaid with .upgraded/")
	} else {
		upgradedDir = ""
		log.Header("materialize candidate tree from " + dbDir)
	}
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
	lr, err := lint.Run(candStepsCfg, candidateDir)
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
		schemas := SchemaUnion(stepsCfg)
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
			reportDiff(diff, liveInv, candInv)
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
				reportDiff(diff2, candInv, cand2Inv)
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
		return fmt.Errorf("reconcile proof failed")
	}
	if opts.DryRun {
		log.Info("dry run: proof manifest not written")
		return nil
	}
	if upgradedDir == "" {
		log.Success("reconcile proof passed against the --db-dir tree")
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

type BuildError struct {
	File string `json:"file"`
	Err  string `json:"error"`
}

type ContainerDiff struct {
	Diff        *InventoryDiff
	BuildErrors []BuildError
	live        map[string]string
	cand        map[string]string
	index       map[string]LiveDiff
	extObjs     map[string]string
}

func (c *ContainerDiff) Candidate() map[string]string {
	return c.cand
}

func CompareToLive(ctx context.Context, live *db.DB, cfg *config.Config, stepsCfg *steps.Config, dbDir, toolVersion string, opts Options) (*ContainerDiff, error) {
	candidateDir, candSteps, err := materializeCandidate(stepsCfg, cfg.StepsFile, dbDir, "")
	if err != nil {
		return nil, err
	}
	if !opts.Keep {
		defer os.RemoveAll(candidateDir)
	}
	candStepsCfg, err := steps.Load(candSteps)
	if err != nil {
		return nil, err
	}
	image := opts.Image
	if image == "" {
		image = imageForServer(ctx, live)
	}
	log.Info("creating a fresh %s and deploying %s into it", image, dbDir)
	cont, cand, err := startContainer(ctx, cfg, image)
	if err != nil {
		return nil, err
	}
	defer cand.Close()
	if !opts.Keep {
		defer stopContainer(cont.Name)
	}

	prev := log.Level
	if log.Level < log.LevelVerbose {
		log.Level = log.LevelSilent
	}
	total, buildErrs, err := buildCandidateResilient(ctx, cand, cont.Cfg, candStepsCfg, candSteps, candidateDir, toolVersion)
	log.Level = prev
	if err != nil {
		return nil, err
	}
	log.Info("deployed %d of %d files into the container, %d build errors", total-len(buildErrs), total, len(buildErrs))

	schemas := SchemaUnion(stepsCfg)
	liveInv, err := Inventory(ctx, live, schemas)
	if err != nil {
		return nil, err
	}
	candInv, err := Inventory(ctx, cand, schemas)
	if err != nil {
		return nil, err
	}
	if opts.Keep {
		log.Plain("container kept: %s on port %d, candidate tree at %s", cont.Name, cont.Port, candidateDir)
	}
	index, _ := collectLocalObjects(stepsCfg, dbDir)
	extObjs, err := ExtensionObjects(ctx, live, schemas)
	if err != nil {
		return nil, err
	}
	return &ContainerDiff{
		Diff:        CompareInventories(liveInv, candInv),
		BuildErrors: buildErrs,
		live:        liveInv,
		cand:        candInv,
		index:       index,
		extObjs:     extObjs,
	}, nil
}

func prepareCandidate(ctx context.Context, cand *db.DB, candStepsCfg *steps.Config, candSteps, candidateDir, toolVersion string) error {
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
	_, err = preflight.Scan(ctx, cand, snap, candStepsCfg, candidateDir)
	return err
}

func bootstrapCandidate(ctx context.Context, cand *db.DB, candCfg *config.Config, candStepsCfg *steps.Config, candSteps, candidateDir, toolVersion string) error {
	if err := prepareCandidate(ctx, cand, candStepsCfg, candSteps, candidateDir, toolVersion); err != nil {
		return err
	}
	pendings, err := apply.ListPending(ctx, cand)
	if err != nil {
		return err
	}
	log.Detail("%d files to apply", len(pendings))
	for _, p := range pendings {
		st, _ := apply.FileRel(candStepsCfg, p.FilePath, candidateDir)
		log.Detail("  %s", p.FilePath)
		if err := apply.File(ctx, cand, p, st, candidateDir, toolVersion, candCfg.PGUser, candCfg.PGHost, candCfg.PGDatabase, false); err != nil {
			return fmt.Errorf("%s: %w", p.FilePath, err)
		}
	}
	return nil
}

func buildCandidateResilient(ctx context.Context, cand *db.DB, candCfg *config.Config, candStepsCfg *steps.Config, candSteps, candidateDir, toolVersion string) (int, []BuildError, error) {
	if err := prepareCandidate(ctx, cand, candStepsCfg, candSteps, candidateDir, toolVersion); err != nil {
		return 0, nil, err
	}
	pendings, err := apply.ListPending(ctx, cand)
	if err != nil {
		return 0, nil, err
	}
	log.Detail("deploying %d files into the local database", len(pendings))
	var errs []BuildError
	for _, p := range pendings {
		st, _ := apply.FileRel(candStepsCfg, p.FilePath, candidateDir)
		if err := apply.File(ctx, cand, p, st, candidateDir, toolVersion, candCfg.PGUser, candCfg.PGHost, candCfg.PGDatabase, false); err != nil {
			errs = append(errs, BuildError{File: p.FilePath, Err: err.Error()})
			log.Detail("  %s  FAILED  %v", p.FilePath, err)
		} else {
			log.Detail("  %s", p.FilePath)
		}
	}
	return len(pendings), errs, nil
}

func SchemaUnion(stepsCfg *steps.Config) []string {
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
