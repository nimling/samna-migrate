package migrate

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	root "github.com/nimling/samna-migrate"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/spf13/cobra"
)

var skillProject bool

var skillCmd = &cobra.Command{
	Use:   "skill",
	Short: "The claude skill that teaches an agent to drive this cli",
}

var skillGetCmd = &cobra.Command{
	Use:   "get [file]",
	Short: "Print the skill document, or one named file from the skill tree",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name := "SKILL.md"
		if len(args) == 1 {
			name = args[0]
		}
		b, err := root.SkillTree.ReadFile(filepath.Join(root.SkillRoot, name))
		if err != nil {
			return fmt.Errorf("no such file in the skill tree: %s", name)
		}
		cmd.Print(string(b))
		return nil
	},
}

var skillPutCmd = &cobra.Command{
	Use:   "put",
	Short: "Install the skill under ~/.claude/skills, or into the current project with --project",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		return installSkill(!skillProject)
	},
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
	skillPutCmd.Flags().BoolVar(&skillProject, "project", false, "Install into .claude of the current directory instead of the home directory")
	skillCmd.AddCommand(skillGetCmd, skillPutCmd)
	rootCmd.AddCommand(skillCmd)
}
