package git

import (
	"os/exec"
	"strings"
)

func IsRepo(dir string) bool {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--git-dir").Output()
	return err == nil && strings.TrimSpace(string(out)) != ""
}

func FileCommit(dir, rel string) string {
	out, err := exec.Command("git", "-C", dir, "log", "-1", "--format=%H", "--", rel).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func DiffSince(dir, commit, rel string) string {
	out, err := exec.Command("git", "-C", dir, "--no-pager", "diff", commit, "--", rel).Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

func Renames(dir, commit, rel string) []string {
	out, err := exec.Command("git", "-C", dir, "log", "--follow", "--name-status", "--format=", commit+"..HEAD", "--", rel).Output()
	if err != nil {
		return nil
	}
	var moves []string
	for _, ln := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		ln = strings.TrimSpace(ln)
		if strings.HasPrefix(ln, "R") {
			moves = append(moves, ln)
		}
	}
	return moves
}
