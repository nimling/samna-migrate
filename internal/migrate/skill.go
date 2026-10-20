package migrate

import (
	"io/fs"
	"path"

	nimcli "github.com/nimling/nimbody/cli"
	root "github.com/nimling/samna-migrate"
	"github.com/nimling/samna-migrate/internal/log"
)

var skillTree = func() fs.FS {
	tree, err := fs.Sub(root.SkillTree, path.Dir(root.SkillRoot))
	if err != nil {
		panic(err)
	}
	return tree
}()

func installSkill() error {
	written, err := nimcli.InstallSkillTree(skillTree, false)
	for _, dir := range written {
		log.Success("installed %s", dir)
	}
	return err
}

func init() {
	rootCmd.AddCommand(nimcli.SkillTreeCommand("smig", skillTree))
}
