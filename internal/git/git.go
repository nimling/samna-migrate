package git

import (
	"fmt"
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

func Root(dir string) string {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func Archive(dir, ref, sub, dst string) error {
	archive := exec.Command("git", "-C", dir, "archive", ref, "--", sub)
	extract := exec.Command("tar", "-x", "-C", dst)
	pipe, err := archive.StdoutPipe()
	if err != nil {
		return err
	}
	extract.Stdin = pipe
	var archiveErr, extractErr strings.Builder
	archive.Stderr = &archiveErr
	extract.Stderr = &extractErr
	if err := extract.Start(); err != nil {
		return err
	}
	if err := archive.Run(); err != nil {
		extract.Wait()
		return fmt.Errorf("git archive %s %s: %s", ref, sub, strings.TrimSpace(archiveErr.String()))
	}
	if err := extract.Wait(); err != nil {
		return fmt.Errorf("extract archive of %s: %s", ref, strings.TrimSpace(extractErr.String()))
	}
	return nil
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
