package reconcile

import (
	"context"
	"os"
	"sort"
	"strings"

	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/hash"
	"github.com/nimling/samna-migrate/internal/sqlscan"
	"github.com/nimling/samna-migrate/internal/steps"
)

const contextLines = 3

type DeployedFile struct {
	FilePath        string
	Position        int
	AppliedPosition int
	State           string
	Sha256          string
	AppliedSha256   string
	AppliedSQL      string
	HasSQL          bool
}

type LocalFile struct {
	FilePath string
	Position int
	Sha256   string
	Content  string
}

func Audit(ctx context.Context, d *db.DB, stepsCfg *steps.Config, dbDir string, stopOnError bool) (*Report, error) {
	deployed, err := loadDeployed(ctx, d)
	if err != nil {
		return nil, err
	}
	local, err := loadLocal(stepsCfg, dbDir)
	if err != nil {
		return nil, err
	}
	return buildReport(local, deployed, stopOnError), nil
}

func loadDeployed(ctx context.Context, d *db.DB) (map[string]DeployedFile, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT file_path, position, COALESCE(applied_position, position), state,
		       sha256, COALESCE(applied_sha256, ''),
		       COALESCE(applied_sql, ''), applied_sql IS NOT NULL
		FROM samna_migrate.file
		WHERE state IN ('applied','reverted','removed','folded')
		ORDER BY COALESCE(applied_position, position)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]DeployedFile{}
	for rows.Next() {
		var f DeployedFile
		if err := rows.Scan(&f.FilePath, &f.Position, &f.AppliedPosition, &f.State,
			&f.Sha256, &f.AppliedSha256, &f.AppliedSQL, &f.HasSQL); err != nil {
			return nil, err
		}
		out[f.FilePath] = f
	}
	return out, rows.Err()
}

func loadLocal(stepsCfg *steps.Config, dbDir string) (map[string]LocalFile, error) {
	out := map[string]LocalFile{}
	pos := 0
	for _, st := range stepsCfg.Steps {
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			pos++
			b, err := os.ReadFile(f.AbsPath)
			if err != nil {
				return nil, err
			}
			sha, err := hash.File(f.AbsPath)
			if err != nil {
				return nil, err
			}
			out[f.Rel] = LocalFile{FilePath: f.Rel, Position: pos, Sha256: sha, Content: string(b)}
		}
	}
	return out, nil
}

func buildReport(local map[string]LocalFile, deployed map[string]DeployedFile, stop bool) *Report {
	r := &Report{}
	paths := unionPaths(local, deployed)
	localRank, deployedRank := commonRanks(local, deployed)

	for _, p := range paths {
		lf, lok := local[p]
		df, dok := deployed[p]
		var fd FileDiff
		switch {
		case lok && !dok:
			fd = FileDiff{FilePath: p, Class: Added, LocalPos: lf.Position}
			fd.Objects = sideObjects(lf.Content, Added)
			fd.FileEdits = Diff(nil, splitLines(lf.Content))
			fd.Hunks = Hunkify(fd.FileEdits, contextLines)
			fd.HasBody = true
		case !lok && dok:
			fd = FileDiff{FilePath: p, Class: Dropped, DeployedPos: df.AppliedPosition, State: df.State, HasBody: df.HasSQL}
			if df.HasSQL {
				fd.Objects = sideObjects(df.AppliedSQL, Dropped)
				fd.FileEdits = Diff(splitLines(df.AppliedSQL), nil)
				fd.Hunks = Hunkify(fd.FileEdits, contextLines)
			}
		default:
			deployedSha := df.AppliedSha256
			if deployedSha == "" {
				deployedSha = df.Sha256
			}
			if lf.Sha256 == deployedSha {
				if localRank[p] != deployedRank[p] {
					fd = FileDiff{FilePath: p, Class: Reordered, LocalPos: lf.Position, DeployedPos: df.AppliedPosition, State: df.State}
				} else {
					r.Same++
					continue
				}
			} else {
				fd = FileDiff{FilePath: p, Class: Changed, LocalPos: lf.Position, DeployedPos: df.AppliedPosition, State: df.State, HasBody: df.HasSQL}
				if df.HasSQL {
					fd.WhitespaceOnly = whitespaceOnly(df.AppliedSQL, lf.Content)
					fd.FileEdits = Diff(splitLines(df.AppliedSQL), splitLines(lf.Content))
					fd.Hunks = Hunkify(fd.FileEdits, contextLines)
					fd.Objects = diffObjects(df.AppliedSQL, lf.Content)
				}
			}
		}

		switch fd.Class {
		case Added:
			r.Added++
		case Dropped:
			r.Dropped++
		case Changed:
			r.Changed++
		case Reordered:
			r.Reordered++
		}
		r.Files = append(r.Files, fd)
		if stop {
			r.Truncated = true
			break
		}
	}
	return r
}

func unionPaths(local map[string]LocalFile, deployed map[string]DeployedFile) []string {
	seen := map[string]bool{}
	var out []string
	for p := range local {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	for p := range deployed {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

func commonRanks(local map[string]LocalFile, deployed map[string]DeployedFile) (map[string]int, map[string]int) {
	var common []string
	for p := range local {
		if _, ok := deployed[p]; ok {
			common = append(common, p)
		}
	}
	byLocal := append([]string{}, common...)
	sort.Slice(byLocal, func(i, j int) bool { return local[byLocal[i]].Position < local[byLocal[j]].Position })
	byDeployed := append([]string{}, common...)
	sort.Slice(byDeployed, func(i, j int) bool {
		return deployed[byDeployed[i]].AppliedPosition < deployed[byDeployed[j]].AppliedPosition
	})
	localRank := map[string]int{}
	deployedRank := map[string]int{}
	for i, p := range byLocal {
		localRank[p] = i
	}
	for i, p := range byDeployed {
		deployedRank[p] = i
	}
	return localRank, deployedRank
}

func objKey(o sqlscan.Object) string {
	return o.Kind + "\x00" + o.Name
}

func sideObjects(content string, class Class) []ObjectDiff {
	objs := sqlscan.Scan(content)
	out := make([]ObjectDiff, 0, len(objs))
	for _, o := range objs {
		od := ObjectDiff{Class: class, Kind: o.Kind, Name: o.Name}
		if class == Added {
			od.LocalLine = o.Line
			od.Hunks = Hunkify(Diff(nil, splitLines(o.SQL)), contextLines)
		} else {
			od.DeployedLine = o.Line
			od.Hunks = Hunkify(Diff(splitLines(o.SQL), nil), contextLines)
		}
		out = append(out, od)
	}
	return out
}

func diffObjects(deployed, local string) []ObjectDiff {
	depObjs := groupByKey(sqlscan.Scan(deployed))
	locObjs := groupByKey(sqlscan.Scan(local))
	keys := mergedKeys(depObjs, locObjs)
	var out []ObjectDiff
	for _, k := range keys {
		dep := depObjs[k]
		loc := locObjs[k]
		n := len(dep)
		if len(loc) > n {
			n = len(loc)
		}
		for i := 0; i < n; i++ {
			switch {
			case i < len(dep) && i < len(loc):
				if normalize(dep[i].SQL) == normalize(loc[i].SQL) {
					continue
				}
				out = append(out, ObjectDiff{
					Class:        Changed,
					Kind:         dep[i].Kind,
					Name:         dep[i].Name,
					DeployedLine: dep[i].Line,
					LocalLine:    loc[i].Line,
					Hunks:        Hunkify(Diff(splitLines(dep[i].SQL), splitLines(loc[i].SQL)), contextLines),
				})
			case i < len(dep):
				out = append(out, ObjectDiff{
					Class:        Dropped,
					Kind:         dep[i].Kind,
					Name:         dep[i].Name,
					DeployedLine: dep[i].Line,
					Hunks:        Hunkify(Diff(splitLines(dep[i].SQL), nil), contextLines),
				})
			default:
				out = append(out, ObjectDiff{
					Class:     Added,
					Kind:      loc[i].Kind,
					Name:      loc[i].Name,
					LocalLine: loc[i].Line,
					Hunks:     Hunkify(Diff(nil, splitLines(loc[i].SQL)), contextLines),
				})
			}
		}
	}
	return out
}

func groupByKey(objs []sqlscan.Object) map[string][]sqlscan.Object {
	out := map[string][]sqlscan.Object{}
	for _, o := range objs {
		k := objKey(o)
		out[k] = append(out[k], o)
	}
	return out
}

func mergedKeys(a, b map[string][]sqlscan.Object) []string {
	seen := map[string]bool{}
	var out []string
	for k := range a {
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	for k := range b {
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

func normalize(s string) string {
	lines := strings.Split(s, "\n")
	for i, ln := range lines {
		lines[i] = strings.TrimRight(ln, " \t")
	}
	return strings.Join(lines, "\n")
}

func whitespaceOnly(a, b string) bool {
	return a != b && normalize(a) == normalize(b)
}
