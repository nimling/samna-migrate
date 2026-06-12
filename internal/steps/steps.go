package steps

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

type IncludeEntry struct {
	Path     string `yaml:"path"`
	Fallback string `yaml:"fallback,omitempty"`
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
		if c.Steps[i].Type == "" {
			c.Steps[i].Type = "base"
		}
		if len(c.Steps[i].Schemas) == 0 {
			c.Steps[i].Schemas = []string{"public"}
		}
	}
	return &c, nil
}

type File struct {
	Step     Step
	AbsPath  string
	Rel      string
	Name     string
	Folder   string
}

func (s *Step) ResolveFiles(dbDir string) ([]File, error) {
	files := []File{}
	seen := map[string]bool{}
	excludes := map[string]bool{}
	for _, e := range s.Exclude {
		excludes[filepath.Base(e.Path)] = true
	}
	for _, inc := range s.Include {
		base := filepath.Clean(filepath.Join(dbDir, inc.Path))
		info, err := os.Stat(base)
		if err != nil {
			if inc.Fallback == "" {
				continue
			}
			base = inc.Fallback
			info, err = os.Stat(base)
			if err != nil {
				continue
			}
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
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	return files, nil
}

func relOrName(dbDir, abs string) string {
	rel, err := filepath.Rel(dbDir, abs)
	if err != nil {
		return abs
	}
	return rel
}

func ParseFilename(name string) (version, slug, label string, ok bool) {
	if !strings.HasSuffix(name, ".sql") {
		return "", "", "", false
	}
	base := strings.TrimSuffix(name, ".sql")
	if !strings.HasPrefix(base, "V") {
		return "", "", "", false
	}
	idx := strings.Index(base, "__")
	if idx < 0 {
		return "", "", "", false
	}
	version = strings.TrimPrefix(base[:idx], "V")
	tail := base[idx+2:]
	under := strings.Index(tail, "_")
	if under < 0 {
		slug = tail
		return version, slug, "", true
	}
	slug = tail[:under]
	label = tail[under+1:]
	return version, slug, label, true
}
