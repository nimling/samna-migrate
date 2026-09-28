package migrate

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/git"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/preflight"
	"github.com/nimling/samna-migrate/internal/reconcile"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/internal/tap"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	testFrom  string
	testKeep  bool
	testImage string
	testJSON  bool
	testRows  string
)

type testFile struct {
	File   string     `json:"file"`
	Folder string     `json:"folder"`
	Result tap.Result `json:"result"`
}

type testContainer struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Database string `json:"database"`
	User     string `json:"user"`
	Password string `json:"password"`
}

type testRun struct {
	Section   string         `json:"section"`
	Passed    bool           `json:"passed"`
	Files     []testFile     `json:"files"`
	Container *testContainer `json:"container,omitempty"`
}

type testReport struct {
	Runs   []testRun `json:"runs"`
	Passed bool      `json:"passed"`
}

var testCmd = &cobra.Command{
	Use:   "test [target]",
	Short: "Run the pgTAP tests against a throwaway postgres built from migrate.yml",
	Long: `test builds every migrate.yml file into a fresh docker postgres carrying pgTAP,
then runs every .sql file under the folders the tests key declares and streams
their TAP output. A target narrows the run to a folder, a file stem, or
folder/stem.

--from=<ref> adds a second run: the database is bootstrapped from the tree at
that git ref, preflight runs against the working tree so a changed base or
seed file replays exactly as it does under up, the migration files new since
the ref are applied twice to prove they are idempotent, and the tests run
again against that upgraded database.

The run fails on any not ok line, a missing or mismatched plan, or a bail out.
--keep leaves the container up and prints its connection. --json emits the
parsed results as one document.`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		cfg, stepsCfg, err := testSetup()
		if err != nil {
			return err
		}
		target := ""
		if len(args) == 1 {
			target = args[0]
		}
		files, err := stepsCfg.TestFiles(dbDir, target)
		if err != nil {
			return err
		}
		if len(files) == 0 {
			if target != "" {
				return fmt.Errorf("no test file matches %q under %s", target, strings.Join(stepsCfg.Tests, ", "))
			}
			return fmt.Errorf("no .sql test files under %s", strings.Join(stepsCfg.Tests, ", "))
		}
		if testJSON {
			log.Level = log.LevelSilent
		}

		report := testReport{Passed: true}
		fresh, err := runTestSuite(ctx, cfg, stepsCfg, "fresh", files, func(c *reconcile.Candidate) error {
			return c.Bootstrap(ctx, cli.Version)
		})
		if err != nil {
			return err
		}
		report.Runs = append(report.Runs, *fresh)
		if testFrom != "" {
			upgraded, err := runUpgradedSuite(ctx, cfg, stepsCfg, files)
			if err != nil {
				return err
			}
			report.Runs = append(report.Runs, *upgraded)
		}

		failing := 0
		for _, r := range report.Runs {
			for _, f := range r.Files {
				if !f.Result.Passed() {
					failing++
				}
			}
			report.Passed = report.Passed && r.Passed
		}
		if testJSON {
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			if err := enc.Encode(report); err != nil {
				return err
			}
		}
		if !report.Passed {
			return fmt.Errorf("test failed: %d file(s) not passing", failing)
		}
		log.Plain("")
		log.Success("test passed: %d file(s) in %d run(s)", len(files), len(report.Runs))
		return nil
	},
}

func testSetup() (*config.Config, *steps.Config, error) {
	if envFile != "" {
		if err := config.LoadDotEnv(envFile); err != nil {
			return nil, nil, err
		}
	}
	cfg := config.FromEnv()
	cfg.StepsFile = stepsFile
	cfg.DBDir = dbDir
	if cfg.PGDatabase == "" {
		cfg.PGDatabase = cfg.PGUser
	}
	if !reconcile.DockerPresent() {
		return nil, nil, fmt.Errorf("test needs docker to build the throwaway database")
	}
	stepsCfg, err := steps.Load(stepsFile)
	if err != nil {
		return nil, nil, err
	}
	if len(stepsCfg.Tests) == 0 {
		return nil, nil, fmt.Errorf("%s declares no tests folder, add tests: [tests]", stepsFile)
	}
	return cfg, stepsCfg, nil
}

func startTestCandidate(ctx context.Context, cfg *config.Config, stepsCfg *steps.Config, stepsPath, dir string) (*reconcile.Candidate, error) {
	c, err := reconcile.StartPgtapCandidate(ctx, cfg, stepsCfg, stepsPath, dir, testImage, testKeep)
	if err != nil {
		return nil, err
	}
	log.Info("container %s on port %d", c.Name, c.Port)
	return c, nil
}

func keepTestContainer(c *reconcile.Candidate) *testContainer {
	if !testKeep {
		return nil
	}
	if !testJSON {
		fmt.Printf("container kept: %s on port %d, candidate tree at %s\n", c.Name, c.Port, c.Dir)
		fmt.Printf("  PGHOST=%s\n", c.Cfg.PGHost)
		fmt.Printf("  PGPORT=%s\n", c.Cfg.PGPort)
		fmt.Printf("  PGDATABASE=%s\n", c.Cfg.PGDatabase)
		fmt.Printf("  PGUSER=%s\n", c.Cfg.PGUser)
		fmt.Printf("  PGPASSWORD=%s\n", c.Cfg.PGPassword)
	}
	return &testContainer{Host: c.Cfg.PGHost, Port: c.Port, Database: c.Cfg.PGDatabase, User: c.Cfg.PGUser, Password: c.Cfg.PGPassword}
}

func runTestSuite(ctx context.Context, cfg *config.Config, stepsCfg *steps.Config, section string, files []string, build func(*reconcile.Candidate) error) (*testRun, error) {
	log.Header("test: " + section)
	c, err := startTestCandidate(ctx, cfg, stepsCfg, stepsFile, dbDir)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	var run *testRun
	defer func() {
		kept := keepTestContainer(c)
		if run != nil {
			run.Container = kept
		}
	}()
	if err := build(c); err != nil {
		return nil, fmt.Errorf("%s: %w", section, err)
	}
	run, err = runTestFiles(ctx, c, section, files)
	if err != nil {
		return nil, err
	}
	return run, nil
}

func runUpgradedSuite(ctx context.Context, cfg *config.Config, stepsCfg *steps.Config, files []string) (*testRun, error) {
	section := "upgraded from " + testFrom
	log.Header("test: " + section)
	root := git.Root(dbDir)
	if root == "" {
		return nil, fmt.Errorf("--from needs %s inside a git repository", dbDir)
	}
	absDb, err := realPath(dbDir)
	if err != nil {
		return nil, err
	}
	absSteps, err := realPath(stepsFile)
	if err != nil {
		return nil, err
	}
	relDb, err := filepath.Rel(root, absDb)
	if err != nil {
		return nil, err
	}
	relSteps, err := filepath.Rel(root, absSteps)
	if err != nil {
		return nil, err
	}
	archive, err := os.MkdirTemp("", "smig-from-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(archive)
	if err := git.Archive(root, testFrom, relDb, archive); err != nil {
		return nil, err
	}
	if !strings.HasPrefix(absSteps, absDb+string(os.PathSeparator)) {
		if err := git.Archive(root, testFrom, relSteps, archive); err != nil {
			return nil, err
		}
	}
	refDb := filepath.Join(archive, relDb)
	refSteps := filepath.Join(archive, relSteps)
	refStepsCfg := stepsCfg
	origin := "migrate.yml from the working tree"
	if _, err := os.Stat(refSteps); err == nil {
		refStepsCfg, err = steps.Load(refSteps)
		if err != nil {
			return nil, fmt.Errorf("migrate.yml at %s: %w", testFrom, err)
		}
		origin = "migrate.yml at " + testFrom
	} else {
		refSteps = stepsFile
	}

	c, err := startTestCandidate(ctx, cfg, refStepsCfg, refSteps, refDb)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	var run *testRun
	defer func() {
		kept := keepTestContainer(c)
		if run != nil {
			run.Container = kept
		}
	}()
	log.Info("bootstrap from the tree at %s, %s", testFrom, origin)
	if err := c.Bootstrap(ctx, cli.Version); err != nil {
		return nil, fmt.Errorf("bootstrap at %s: %w", testFrom, err)
	}

	snap, err := schema.Snapshot(ctx, c.DB, stepsFile)
	if err != nil {
		return nil, err
	}
	if err := schema.WriteYAMLSha(ctx, c.DB, snap.DiskYAMLSha, cli.Version); err != nil {
		return nil, err
	}
	prev := log.Level
	if log.Level < log.LevelVerbose {
		log.Level = log.LevelSilent
	}
	_, err = preflight.Scan(ctx, c.DB, snap, stepsCfg, dbDir)
	log.Level = prev
	if err != nil {
		return nil, err
	}
	pendings, err := apply.ListPending(ctx, c.DB)
	if err != nil {
		return nil, err
	}
	migrations, replayed := 0, 0
	for _, p := range pendings {
		if p.StepType == "migration" {
			migrations++
		} else {
			replayed++
		}
	}
	log.Info("%d migration file(s) new since %s, %d base and seed file(s) replayed", migrations, testFrom, replayed)
	for _, p := range pendings {
		st, err := apply.FileRel(stepsCfg, p.FilePath, dbDir)
		if err != nil {
			return nil, err
		}
		passes := 1
		if p.StepType == "migration" {
			passes = 2
		}
		for pass := 1; pass <= passes; pass++ {
			if err := apply.File(ctx, c.DB, p, st, dbDir, cli.Version, c.Cfg.PGUser, c.Cfg.PGHost, c.Cfg.PGDatabase, false); err != nil {
				if pass == 2 {
					return nil, fmt.Errorf("%s is not idempotent, second apply failed: %w", p.FilePath, err)
				}
				return nil, fmt.Errorf("%s failed: %w", p.FilePath, err)
			}
		}
		if passes == 2 {
			log.Detail("  %s applied twice", p.FilePath)
		} else {
			log.Detail("  %s replayed", p.FilePath)
		}
	}

	run, err = runTestFiles(ctx, c, section, files)
	if err != nil {
		return nil, err
	}
	return run, nil
}

func realPath(p string) (string, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(abs)
}

func testRel(p string) string {
	abs, err := filepath.Abs(dbDir)
	if err != nil {
		return p
	}
	rel, err := filepath.Rel(abs, p)
	if err != nil {
		return p
	}
	return filepath.ToSlash(rel)
}

func printTapLine(line string) {
	if testJSON {
		return
	}
	switch {
	case tap.IsFailure(line):
		log.Err("%s", line)
	case log.Level == log.LevelSilent:
	case tap.IsDiag(line):
		log.Detail("%s", line)
	default:
		log.Plain("%s", line)
	}
}

func runTestFiles(ctx context.Context, c *reconcile.Candidate, section string, files []string) (*testRun, error) {
	if _, err := c.DB.Pool.Exec(ctx, `CREATE EXTENSION IF NOT EXISTS pgtap`); err != nil {
		return nil, fmt.Errorf("create extension pgtap: %w", err)
	}
	run := &testRun{Section: section, Passed: true, Files: []testFile{}}
	rightEdge := 0
	perFolder := map[string]int{}
	for _, p := range files {
		perFolder[filepath.Dir(testRel(p))]++
		if w := 4 + len(filepath.Base(p)) + 2 + len("000 ok"); w > rightEdge {
			rightEdge = w
		}
	}
	folder := ""
	for _, p := range files {
		rel := testRel(p)
		if dir := filepath.Dir(rel); dir != folder {
			folder = dir
			log.Section(folder, fmt.Sprintf("%d file(s)", perFolder[dir]), rightEdge)
		}
		body, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		var lines []string
		err = c.DB.Batch(ctx, string(body), func(value string) {
			for _, line := range strings.Split(strings.TrimRight(value, "\n"), "\n") {
				lines = append(lines, line)
				printTapLine(line)
			}
		})
		if err != nil {
			bail := "Bail out! " + strings.ReplaceAll(err.Error(), "\n", " ")
			lines = append(lines, bail)
			printTapLine(bail)
		}
		result := tap.Parse(lines)
		name := filepath.Base(p)
		switch {
		case result.Passed():
			log.Step(name, fmt.Sprintf("%d ok", result.Ok), rightEdge)
		case result.BailOut:
			log.Err("  ✗ %s  %d ok, %d not ok, bailed out", name, result.Ok, result.NotOk)
		case result.Plan == 0:
			log.Err("  ✗ %s  %d ok, %d not ok, no plan", name, result.Ok, result.NotOk)
		case result.Missing > 0:
			log.Err("  ✗ %s  %d ok, %d not ok, plan %d mismatched by %d", name, result.Ok, result.NotOk, result.Plan, result.Missing)
		default:
			log.Err("  ✗ %s  %d ok, %d not ok", name, result.Ok, result.NotOk)
		}
		run.Passed = run.Passed && result.Passed()
		run.Files = append(run.Files, testFile{File: rel, Folder: folder, Result: result})
	}
	return run, nil
}

var testNewCmd = &cobra.Command{
	Use:   "new <name>",
	Short: "Write a pgTAP test file skeleton into the tests folder",
	Long: `test new writes <tests dir>/<name>.sql with a BEGIN, plan, one assertion,
finish and ROLLBACK. When migrate.yml declares several tests folders the name
is given as folder/name to pick one.

--rows="<sql>" builds the throwaway database exactly as test does, runs the
query once, and writes a results_eq assertion with the observed rows as typed
literals in place of the placeholder. On an existing file the assertion is
appended and plan(n) is bumped.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		cfg, stepsCfg, err := testSetup()
		if err != nil {
			return err
		}
		folder, name := "", args[0]
		if i := strings.LastIndex(name, "/"); i >= 0 {
			folder, name = name[:i], name[i+1:]
		}
		name = strings.TrimSuffix(name, ".sql")
		if name == "" {
			return fmt.Errorf("test new needs a file name")
		}
		dir, err := testDir(stepsCfg, folder)
		if err != nil {
			return err
		}
		path := filepath.Join(dir, name+".sql")
		_, statErr := os.Stat(path)
		exists := statErr == nil
		if exists && testRows == "" {
			return fmt.Errorf("%s exists, pass --rows=<sql> to append an assertion", path)
		}

		assertion := fmt.Sprintf("SELECT ok(true, '%s');", sqlQuote(name))
		if testRows != "" {
			assertion, err = rowsAssertion(ctx, cfg, stepsCfg, name, testRows)
			if err != nil {
				return err
			}
		}
		if exists {
			if err := appendAssertion(path, assertion); err != nil {
				return err
			}
			log.Success("appended an assertion to %s", path)
			return nil
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		body := "BEGIN;\nSELECT plan(1);\n" + assertion + "\nSELECT * FROM finish();\nROLLBACK;\n"
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			return err
		}
		log.Success("wrote %s", path)
		return nil
	},
}

func testDir(stepsCfg *steps.Config, folder string) (string, error) {
	dirs := stepsCfg.TestDirs(dbDir)
	if folder == "" {
		if len(dirs) > 1 {
			return "", fmt.Errorf("%s declares %d tests folders, name the file as folder/name", stepsFile, len(dirs))
		}
		return dirs[0], nil
	}
	want := strings.Trim(folder, "/")
	for i, d := range dirs {
		if strings.Trim(stepsCfg.Tests[i], "/") == want || filepath.Base(d) == want {
			return d, nil
		}
	}
	return "", fmt.Errorf("no tests folder named %q in %s", folder, stepsFile)
}

var rxPlan = regexp.MustCompile(`SELECT\s+plan\(\s*(\d+)\s*\)\s*;`)

func appendAssertion(path, assertion string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	body := string(raw)
	m := rxPlan.FindStringSubmatchIndex(body)
	if m == nil {
		return fmt.Errorf("%s has no SELECT plan(n); line to bump", path)
	}
	n, _ := strconv.Atoi(body[m[2]:m[3]])
	body = body[:m[2]] + strconv.Itoa(n+1) + body[m[3]:]
	finish := strings.Index(body, "SELECT * FROM finish();")
	if finish < 0 {
		return fmt.Errorf("%s has no SELECT * FROM finish(); line to insert before", path)
	}
	body = body[:finish] + assertion + "\n" + body[finish:]
	return os.WriteFile(path, []byte(body), 0o644)
}

func sqlQuote(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

func rowsAssertion(ctx context.Context, cfg *config.Config, stepsCfg *steps.Config, name, query string) (string, error) {
	log.Header("test new: build the database for --rows")
	c, err := startTestCandidate(ctx, cfg, stepsCfg, stepsFile, dbDir)
	if err != nil {
		return "", err
	}
	defer c.Close()
	if err := c.Bootstrap(ctx, cli.Version); err != nil {
		return "", err
	}
	rows, err := c.DB.Pool.Query(ctx, query, pgx.QueryExecModeSimpleProtocol)
	if err != nil {
		return "", fmt.Errorf("--rows query: %w", err)
	}
	var oids []uint32
	for _, fd := range rows.FieldDescriptions() {
		oids = append(oids, fd.DataTypeOID)
	}
	var observed [][]*string
	for rows.Next() {
		raw := rows.RawValues()
		row := make([]*string, len(raw))
		for i, v := range raw {
			if v != nil {
				s := string(v)
				row[i] = &s
			}
		}
		observed = append(observed, row)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("--rows query: %w", err)
	}
	types := make([]string, len(oids))
	for i, oid := range oids {
		if err := c.DB.Pool.QueryRow(ctx, `SELECT format_type($1::oid, -1)`, oid).Scan(&types[i]); err != nil {
			return "", err
		}
	}
	if len(observed) == 0 {
		return fmt.Sprintf("SELECT is_empty($$%s$$, '%s');", query, sqlQuote(name)), nil
	}
	values := make([]string, len(observed))
	for r, row := range observed {
		cells := make([]string, len(row))
		for i, v := range row {
			if v == nil {
				cells[i] = "NULL::" + types[i]
				continue
			}
			cells[i] = "'" + sqlQuote(*v) + "'::" + types[i]
		}
		values[r] = "(" + strings.Join(cells, ", ") + ")"
	}
	return fmt.Sprintf("SELECT results_eq($$%s$$, $$VALUES %s$$, '%s');", query, strings.Join(values, ", "), sqlQuote(name)), nil
}

func init() {
	testCmd.Flags().StringVar(&testFrom, "from", "", "Git ref to bootstrap from, then upgrade with the working tree and run the tests again")
	testCmd.Flags().BoolVar(&testKeep, "keep", false, "Leave the container and candidate tree in place for inspection")
	testCmd.Flags().StringVar(&testImage, "image", "", "Postgres docker image the pgTAP image derives from, defaults to postgres:17")
	testCmd.Flags().BoolVar(&testJSON, "json", false, "Emit the parsed results as JSON")
	testNewCmd.Flags().StringVar(&testRows, "rows", "", "SQL whose observed rows become a results_eq assertion")
	testNewCmd.Flags().StringVar(&testImage, "image", "", "Postgres docker image the pgTAP image derives from, defaults to postgres:17")
	testCmd.AddCommand(testNewCmd)
	rootCmd.AddCommand(testCmd)
}
