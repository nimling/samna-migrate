package cli

import "runtime/debug"

var (
	Version       = "dev"
	BuildTime     = "unknown"
	GitCommit     = "unknown"
	SchemaVersion = 5
	AnthropicKey  = ""
	Model         = "claude-sonnet-4-6"
)

func init() {
	if Version != "dev" {
		return
	}
	if bi, ok := debug.ReadBuildInfo(); ok {
		if v := bi.Main.Version; v != "" && v != "(devel)" {
			Version = v
		}
	}
}
