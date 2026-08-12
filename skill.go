package samnamigrate

import "embed"

//go:embed all:.claude/skills/smig
var SkillTree embed.FS

const SkillRoot = ".claude/skills/smig"
