# The smig cli

The cli is built to the `cli` skill in `~/.claude/skills/cli`. This file is what a change here must carry.

1. Source: `internal/migrate`. Entry: `cmd/main.go`, `os.Exit(migrate.Execute())` through `cli.Execute` of `nimbody/cli`. The command table: `internal/migrate/root.go` and one file per command beside it; `mcp.go`, `skill.go` and `plugin.go` mount `cli.MCPCommand`, `cli.SkillTreeCommand` and `cli.PluginCommand`; `config.go` holds the `cli.Settings` keys and mounts `cli.ConfigCommand`. Colour is `internal/log/log.go` on `cli.Colour`. Build and install: `just build`, `just install`. Test: `just test`, `just test-go`.
2. A new or changed command updates, in the same commit:
   2.1. its Short, usage and one example;
   2.2. its MCP annotation (`mcp: read|write|destructive`) or the reason it is not a tool;
   2.3. the bundled skill `.claude/skills/smig/SKILL.md` where the change is something a caller must know;
   2.4. the test that pins its flags, json output and exit code.
3. Output, exit codes, config, credentials and the MCP server come from the shared module. A change to any of them is made there, released, and pinned here; never patched locally.
4. Release: `just deploy` (sbump). The plugin version moves with it; `smig plugin status` reads clean after install.
5. Check: `~/.claude/skills/cli/scripts/audit.sh smig` passes before the release.
   5.1. Still failing: `2 tooling command status exists`; smig has `stat` and no `status`.
