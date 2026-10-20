package log

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/nimling/nimbody/cli"
)

const (
	colorReset  = "\033[0m"
	colorRed    = "\033[31m"
	colorGreen  = "\033[32m"
	colorYellow = "\033[33m"
	colorCyan   = "\033[36m"
	colorGray   = "\033[90m"
	colorFaint  = "\033[38;5;240m"
	colorWhite  = "\033[37m"
	colorBold   = "\033[1m"
)

const (
	LevelSilent = iota
	LevelNormal
	LevelVerbose
	LevelExtreme
)

var Level = LevelNormal

func paint(out io.Writer, color, text string) string {
	if text == "" || !cli.Colour(out) {
		return text
	}
	return color + text + colorReset
}

func Header(msg string) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("\n%s\n", paint(os.Stdout, colorBold+colorCyan, msg))
}

func Section(title, right string, rightEdge int) {
	if Level == LevelSilent {
		return
	}
	pad := rightEdge - 2 - len(title) - len(right)
	if pad < 1 {
		pad = 1
	}
	fmt.Printf("\n%s%s%s\n", paint(os.Stdout, colorBold+colorCyan, "▸ "+title), strings.Repeat(" ", pad), paint(os.Stdout, colorGray, right))
}

func Detail(format string, args ...any) {
	if Level < LevelVerbose {
		return
	}
	fmt.Printf("%s\n", paint(os.Stdout, colorGray, fmt.Sprintf(format, args...)))
}

func Dim(format string, args ...any) {
	if Level < LevelVerbose {
		return
	}
	fmt.Printf("%s\n", paint(os.Stdout, colorFaint, fmt.Sprintf(format, args...)))
}

func Dump(format string, args ...any) {
	if Level < LevelExtreme {
		return
	}
	fmt.Printf("%s\n", paint(os.Stdout, colorFaint, fmt.Sprintf(format, args...)))
}

func Info(format string, args ...any) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("%s\n", paint(os.Stdout, colorGray, fmt.Sprintf(format, args...)))
}

func Success(format string, args ...any) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("%s\n", paint(os.Stdout, colorGreen, fmt.Sprintf(format, args...)))
}

func Warn(format string, args ...any) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("%s\n", paint(os.Stdout, colorYellow, fmt.Sprintf(format, args...)))
}

func Err(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s\n", paint(os.Stderr, colorRed, fmt.Sprintf(format, args...)))
}

func Plain(format string, args ...any) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf(format+"\n", args...)
}

func Step(name, detail string, rightEdge int) {
	if Level == LevelSilent {
		return
	}
	pad := rightEdge - 4 - len(name) - len(detail)
	if pad < 1 {
		pad = 1
	}
	fmt.Printf("  %s %s%s%s\n", paint(os.Stdout, colorGreen, "✓"), name, strings.Repeat(" ", pad), paint(os.Stdout, colorGray, detail))
}

func DiffHunk(header string) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("%s\n", paint(os.Stdout, colorCyan, header))
}

func DiffLine(op rune, text string) {
	if Level == LevelSilent {
		return
	}
	color := colorGray
	switch op {
	case '+':
		color = colorGreen
	case '-':
		color = colorRed
	}
	fmt.Printf("%s\n", paint(os.Stdout, color, fmt.Sprintf("%c %s", op, text)))
}

func Fatal(format string, args ...any) {
	Err(format, args...)
	os.Exit(1)
}
