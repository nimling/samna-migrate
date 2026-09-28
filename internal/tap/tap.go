package tap

import (
	"strconv"
	"strings"
)

type Result struct {
	Plan     int      `json:"plan"`
	Ok       int      `json:"ok"`
	NotOk    int      `json:"not_ok"`
	Missing  int      `json:"missing"`
	BailOut  bool     `json:"bail_out"`
	Failures []string `json:"failures"`
}

func (r Result) Passed() bool {
	return !r.BailOut && r.NotOk == 0 && r.Missing == 0 && r.Plan > 0
}

func Parse(lines []string) Result {
	r := Result{Failures: []string{}}
	planned := false
	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		switch {
		case line == "":
		case strings.HasPrefix(line, "Bail out!"):
			r.BailOut = true
			r.Failures = append(r.Failures, line)
		case strings.HasPrefix(line, "#"):
		case strings.HasPrefix(line, "1.."):
			if n, err := strconv.Atoi(strings.TrimSpace(line[3:])); err == nil {
				r.Plan = n
				planned = true
			}
		case strings.HasPrefix(line, "not ok"):
			r.NotOk++
			r.Failures = append(r.Failures, line)
		case strings.HasPrefix(line, "ok"):
			r.Ok++
		}
	}
	if planned {
		if ran := r.Ok + r.NotOk; ran < r.Plan {
			r.Missing = r.Plan - ran
		} else {
			r.Missing = ran - r.Plan
		}
	}
	return r
}

func IsDiag(line string) bool {
	return strings.HasPrefix(strings.TrimSpace(line), "#")
}

func IsFailure(line string) bool {
	t := strings.TrimSpace(line)
	return strings.HasPrefix(t, "not ok") || strings.HasPrefix(t, "Bail out!")
}
