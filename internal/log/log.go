package log

import (
	"fmt"
	"os"
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

func Header(msg string) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("\n%s%s%s%s\n", colorBold, colorCyan, msg, colorReset)
}

func Section(title, right string) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("\n%s%s▸ %s%s  %s%s%s\n", colorBold, colorCyan, title, colorReset, colorGray, right, colorReset)
}

func Detail(format string, args ...any) {
	if Level < LevelVerbose {
		return
	}
	fmt.Printf("%s%s%s\n", colorGray, fmt.Sprintf(format, args...), colorReset)
}

func Dim(format string, args ...any) {
	if Level < LevelVerbose {
		return
	}
	fmt.Printf("%s%s%s\n", colorFaint, fmt.Sprintf(format, args...), colorReset)
}

func Dump(format string, args ...any) {
	if Level < LevelExtreme {
		return
	}
	fmt.Printf("%s%s%s\n", colorFaint, fmt.Sprintf(format, args...), colorReset)
}

func Info(format string, args ...any) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("%s%s%s\n", colorGray, fmt.Sprintf(format, args...), colorReset)
}

func Success(format string, args ...any) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("%s%s%s\n", colorGreen, fmt.Sprintf(format, args...), colorReset)
}

func Warn(format string, args ...any) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("%s%s%s\n", colorYellow, fmt.Sprintf(format, args...), colorReset)
}

func Err(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s%s%s\n", colorRed, fmt.Sprintf(format, args...), colorReset)
}

func Plain(format string, args ...any) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf(format+"\n", args...)
}

func Step(name, detail string) {
	if Level == LevelSilent {
		return
	}
	fmt.Printf("  %s✓%s %s%s%s%s\n", colorGreen, colorReset, name, colorGray, detail, colorReset)
}

func Fatal(format string, args ...any) {
	Err(format, args...)
	os.Exit(1)
}
