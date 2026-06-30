package steps

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"
)

type IncludeEntry struct {
	Path     string `yaml:"path"`
	Fallback string `yaml:"fallback,omitempty"`
	Git      string `yaml:"git,omitempty"`
	Ref      string `yaml:"ref,omitempty"`
	URL      string `yaml:"url,omitempty"`
}

func (e *IncludeEntry) UnmarshalYAML(node *yaml.Node) error {
	if node.Kind == yaml.ScalarNode {
		e.Path = node.Value
		return nil
	}
	type plain IncludeEntry
	return node.Decode((*plain)(e))
}

type Step struct {
	Name     string            `yaml:"name"`
	Type     string            `yaml:"type"`
	Slug     string            `yaml:"slug"`
	Schemas  []string          `yaml:"schemas"`
	If       string            `yaml:"if"`
	Vars     map[string]string `yaml:"vars"`
	Include  []IncludeEntry    `yaml:"include"`
	Exclude  []IncludeEntry    `yaml:"exclude"`
	Pre      string            `yaml:"pre,omitempty"`
	Post     string            `yaml:"post,omitempty"`
}

type Config struct {
	Name        string `yaml:"name"`
	Description string `yaml:"description"`
	Version     string `yaml:"version"`
	Steps       []Step `yaml:"steps"`
}

var validTypes = map[string]bool{"base": true, "migration": true, "seed": true}

func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := yaml.Unmarshal(b, &c); err != nil {
		return nil, err
	}
	for i := range c.Steps {
		st := &c.Steps[i]
		if st.Type == "" {
			return nil, fmt.Errorf("step %q: type is required, want base, migration, or seed", st.Name)
		}
		if !validTypes[st.Type] {
			return nil, fmt.Errorf("step %q: type %q is invalid, want base, migration, or seed", st.Name, st.Type)
		}
		if st.Type == "migration" && st.Slug != "" {
			return nil, fmt.Errorf("step %q: a migration step must not declare a slug, its files target slugs declared by other steps", st.Name)
		}
		if st.Type != "migration" && st.Slug == "" {
			return nil, fmt.Errorf("step %q: a %s step must declare a slug", st.Name, st.Type)
		}
		if len(st.Schemas) == 0 {
			st.Schemas = []string{"public"}
		}
	}
	return &c, nil
}

func (c *Config) Slugs() map[string]bool {
	out := map[string]bool{}
	for _, st := range c.Steps {
		if st.Slug != "" {
			out[st.Slug] = true
		}
	}
	return out
}

type File struct {
	Step    Step
	AbsPath string
	Rel     string
	Name    string
	Folder  string
}

func resolveIncludePath(dbDir, p string) string {
	p = os.ExpandEnv(p)
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Clean(filepath.Join(dbDir, p))
}

var (
	remoteMu    sync.Mutex
	remoteCache = map[string]string{}
)

// source materializes the include into a local directory or file path. A local
// path resolves through path then fallback and reports found=false when neither
// exists. A git or url source is fetched once per run and any failure is
// returned as an error rather than skipped.
func (inc IncludeEntry) source(dbDir string) (string, bool, error) {
	switch {
	case inc.Git != "":
		dir, err := fetchGit(inc.Git, inc.Ref, inc.Path)
		if err != nil {
			return "", false, err
		}
		return dir, true, nil
	case inc.URL != "":
		dir, err := fetchURL(inc.URL, inc.Path)
		if err != nil {
			return "", false, err
		}
		return dir, true, nil
	default:
		base := resolveIncludePath(dbDir, inc.Path)
		if _, err := os.Stat(base); err == nil {
			return base, true, nil
		}
		if inc.Fallback == "" {
			return "", false, nil
		}
		base = resolveIncludePath(dbDir, inc.Fallback)
		if _, err := os.Stat(base); err == nil {
			return base, true, nil
		}
		return "", false, nil
	}
}

// fetchGit clones only the requested subfolder of a git repo at a ref using a
// shallow sparse checkout, returning the local path of that subfolder. The git
// binary handles ssh and https with the caller's existing credentials.
func fetchGit(repo, ref, sub string) (string, error) {
	if ref == "" {
		ref = "main"
	}
	key := "git\x00" + repo + "\x00" + ref
	remoteMu.Lock()
	root, ok := remoteCache[key]
	remoteMu.Unlock()
	if !ok {
		dir, err := os.MkdirTemp("", "smig-git-")
		if err != nil {
			return "", err
		}
		clone := exec.Command("git", "clone", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", ref, repo, dir)
		if out, err := clone.CombinedOutput(); err != nil {
			return "", fmt.Errorf("git clone %s@%s: %w: %s", repo, ref, err, strings.TrimSpace(string(out)))
		}
		root = dir
		remoteMu.Lock()
		remoteCache[key] = root
		remoteMu.Unlock()
	}
	if sub != "" {
		set := exec.Command("git", "-C", root, "sparse-checkout", "set", sub)
		if out, err := set.CombinedOutput(); err != nil {
			return "", fmt.Errorf("git sparse-checkout %s in %s@%s: %w: %s", sub, repo, ref, err, strings.TrimSpace(string(out)))
		}
	}
	full := filepath.Join(root, filepath.FromSlash(sub))
	if _, err := os.Stat(full); err != nil {
		return "", fmt.Errorf("subfolder %q not found in %s@%s", sub, repo, ref)
	}
	return full, nil
}

// fetchURL downloads a non git archive over http, extracts it once per run, and
// returns the requested subfolder inside it. Any failure is returned as an error.
func fetchURL(rawURL, sub string) (string, error) {
	key := "url\x00" + rawURL
	remoteMu.Lock()
	root, ok := remoteCache[key]
	remoteMu.Unlock()
	if !ok {
		resp, err := http.Get(rawURL)
		if err != nil {
			return "", fmt.Errorf("download %s: %w", rawURL, err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return "", fmt.Errorf("download %s: %s", rawURL, resp.Status)
		}
		dir, err := os.MkdirTemp("", "smig-url-")
		if err != nil {
			return "", err
		}
		if err := extractArchive(rawURL, resp.Body, dir); err != nil {
			return "", fmt.Errorf("extract %s: %w", rawURL, err)
		}
		root = dir
		remoteMu.Lock()
		remoteCache[key] = root
		remoteMu.Unlock()
	}
	full := filepath.Join(root, filepath.FromSlash(sub))
	if _, err := os.Stat(full); err != nil {
		return "", fmt.Errorf("subfolder %q not found in %s", sub, rawURL)
	}
	return full, nil
}

func extractArchive(name string, r io.Reader, dst string) error {
	switch {
	case strings.HasSuffix(name, ".zip"):
		data, err := io.ReadAll(r)
		if err != nil {
			return err
		}
		zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
		if err != nil {
			return err
		}
		for _, f := range zr.File {
			if err := writeUnder(dst, f.Name, f.FileInfo().IsDir(), f.Open); err != nil {
				return err
			}
		}
		return nil
	case strings.HasSuffix(name, ".tar.gz"), strings.HasSuffix(name, ".tgz"):
		gz, err := gzip.NewReader(r)
		if err != nil {
			return err
		}
		defer gz.Close()
		tr := tar.NewReader(gz)
		for {
			hd, err := tr.Next()
			if err == io.EOF {
				break
			}
			if err != nil {
				return err
			}
			open := func() (io.ReadCloser, error) { return io.NopCloser(tr), nil }
			if err := writeUnder(dst, hd.Name, hd.Typeflag == tar.TypeDir, open); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("unsupported archive %q, want .zip, .tar.gz, or .tgz", name)
	}
}

func writeUnder(dst, name string, isDir bool, open func() (io.ReadCloser, error)) error {
	target := filepath.Join(dst, filepath.FromSlash(name))
	clean := filepath.Clean(dst)
	if target != clean && !strings.HasPrefix(target, clean+string(os.PathSeparator)) {
		return fmt.Errorf("archive entry escapes destination: %q", name)
	}
	if isDir {
		return os.MkdirAll(target, 0o755)
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	rc, err := open()
	if err != nil {
		return err
	}
	defer rc.Close()
	out, err := os.Create(target)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, rc)
	return err
}

func (s *Step) ResolveFiles(dbDir string) ([]File, error) {
	files := []File{}
	seen := map[string]bool{}
	excludes := map[string]bool{}
	for _, e := range s.Exclude {
		excludes[filepath.Base(e.Path)] = true
	}
	for _, inc := range s.Include {
		base, found, err := inc.source(dbDir)
		if err != nil {
			return nil, err
		}
		if !found {
			continue
		}
		info, err := os.Stat(base)
		if err != nil {
			return nil, fmt.Errorf("stat %s: %w", base, err)
		}
		if info.IsDir() {
			entries, err := os.ReadDir(base)
			if err != nil {
				return nil, fmt.Errorf("readdir %s: %w", base, err)
			}
			for _, ent := range entries {
				if ent.IsDir() {
					continue
				}
				name := ent.Name()
				if !strings.HasSuffix(name, ".sql") {
					continue
				}
				if excludes[name] {
					continue
				}
				abs := filepath.Join(base, name)
				rel := relOrName(dbDir, abs)
				if seen[rel] {
					continue
				}
				seen[rel] = true
				files = append(files, File{
					Step:    *s,
					AbsPath: abs,
					Rel:     rel,
					Name:    name,
					Folder:  filepath.Base(base),
				})
			}
		} else {
			name := info.Name()
			if excludes[name] {
				continue
			}
			rel := relOrName(dbDir, base)
			if seen[rel] {
				return files, nil
			}
			seen[rel] = true
			files = append(files, File{
				Step:    *s,
				AbsPath: base,
				Rel:     rel,
				Name:    name,
				Folder:  filepath.Base(filepath.Dir(base)),
			})
		}
	}
	sort.Slice(files, func(i, j int) bool {
		vi, _, _, oki := ParseFilename(files[i].Name)
		vj, _, _, okj := ParseFilename(files[j].Name)
		if oki && okj {
			if c := compareVersion(vi, vj); c != 0 {
				return c < 0
			}
		}
		return files[i].Name < files[j].Name
	})
	return files, nil
}

// compareVersion orders dotted numeric versions component by component, so
// V1.2 precedes V1.10 and V5.0 precedes V10.0, where a plain string sort would
// not. Non numeric components fall back to string comparison.
func compareVersion(a, b string) int {
	as := strings.Split(a, ".")
	bs := strings.Split(b, ".")
	n := len(as)
	if len(bs) > n {
		n = len(bs)
	}
	for i := 0; i < n; i++ {
		var ai, bi string
		if i < len(as) {
			ai = as[i]
		}
		if i < len(bs) {
			bi = bs[i]
		}
		an, aerr := strconv.Atoi(ai)
		bn, berr := strconv.Atoi(bi)
		if aerr == nil && berr == nil {
			if an != bn {
				if an < bn {
					return -1
				}
				return 1
			}
			continue
		}
		if ai != bi {
			if ai < bi {
				return -1
			}
			return 1
		}
	}
	return 0
}

func relOrName(dbDir, abs string) string {
	rel, err := filepath.Rel(dbDir, abs)
	if err != nil {
		return abs
	}
	return rel
}

var rxFilename = regexp.MustCompile(`^V([1-9][0-9]*(?:\.[0-9]+)*)__([a-z0-9]+)_([a-z0-9_]+)\.sql$`)

func ParseFilename(name string) (version, slug, label string, ok bool) {
	m := rxFilename.FindStringSubmatch(name)
	if m == nil {
		return "", "", "", false
	}
	return m[1], m[2], m[3], true
}

// Active evaluates the step's if expression with sh. An empty expression
// means the step always runs, mirroring eval_condition in migrate.sh.
func (s *Step) Active() bool {
	cond := strings.TrimSpace(s.If)
	if cond == "" || cond == "null" {
		return true
	}
	return exec.Command("sh", "-c", cond).Run() == nil
}

// ExpandVars resolves each vars value through sh so env references and
// command substitutions behave exactly as eval echo does in migrate.sh.
func (s *Step) ExpandVars() (map[string]string, error) {
	if len(s.Vars) == 0 {
		return nil, nil
	}
	out := make(map[string]string, len(s.Vars))
	for k, v := range s.Vars {
		b, err := exec.Command("sh", "-c", `printf %s "`+v+`"`).Output()
		if err != nil {
			return nil, fmt.Errorf("expand var %s: %w", k, err)
		}
		out[k] = string(b)
	}
	return out, nil
}
