package migrate

import (
	"io/fs"
	"os"
	"path/filepath"

	nimcli "github.com/nimling/nimbody/cli"
	root "github.com/nimling/samna-migrate"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/spf13/cobra"
)

var skillDocument = func() string {
	document, err := root.SkillTree.ReadFile(root.SkillRoot + "/SKILL.md")
	if err != nil {
		panic(err)
	}
	return string(document)
}()

func skillCmd() *cobra.Command {
	skill := nimcli.SkillCommand("smig", skillDocument)
	for _, child := range skill.Commands() {
		if child.Name() != "install" {
			continue
		}
		child.Short = "Install the whole skill tree under ~/.claude/skills, or into the current project with --project"
		child.RunE = func(cmd *cobra.Command, args []string) error {
			project, err := cmd.Flags().GetBool("project")
			if err != nil {
				return err
			}
			return installSkill(!project)
		}
	}
	return skill
}

func installSkill(global bool) error {
	base := ".claude"
	if global {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		base = filepath.Join(home, ".claude")
	}
	dest := filepath.Join(base, "skills", "smig")

	written := 0
	err := fs.WalkDir(root.SkillTree, root.SkillRoot, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root.SkillRoot, p)
		if err != nil {
			return err
		}
		target := filepath.Join(dest, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		b, err := root.SkillTree.ReadFile(p)
		if err != nil {
			return err
		}
		if err := os.WriteFile(target, b, 0o644); err != nil {
			return err
		}
		log.Detail("  wrote %s", target)
		written++
		return nil
	})
	if err != nil {
		return err
	}

	log.Success("installed %d file(s) into %s", written, dest)
	return nil
}

func init() {
	rootCmd.AddCommand(skillCmd())
}
