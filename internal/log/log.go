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
	colorWhite  = "\033[37m"
	colorBold   = "\033[1m"
)

var Verbose bool

func Header(msg string) {
	fmt.Printf("\n%s%s%s%s\n", colorBold, colorCyan, msg, colorReset)
}

func Section(title, right string) {
	fmt.Printf("\n%s%s▸ %s%s  %s%s%s\n", colorBold, colorCyan, title, colorReset, colorGray, right, colorReset)
}

func Detail(format string, args ...any) {
	if !Verbose {
		return
	}
	fmt.Printf("%s%s%s\n", colorGray, fmt.Sprintf(format, args...), colorReset)
}

func Info(format string, args ...any) {
	fmt.Printf("%s%s%s\n", colorGray, fmt.Sprintf(format, args...), colorReset)
}

func Success(format string, args ...any) {
	fmt.Printf("%s%s%s\n", colorGreen, fmt.Sprintf(format, args...), colorReset)
}

func Warn(format string, args ...any) {
	fmt.Printf("%s%s%s\n", colorYellow, fmt.Sprintf(format, args...), colorReset)
}

func Err(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s%s%s\n", colorRed, fmt.Sprintf(format, args...), colorReset)
}

func Plain(format string, args ...any) {
	fmt.Printf(format+"\n", args...)
}

func Step(name, detail string) {
	fmt.Printf("  %s✓%s %s%s%s%s\n", colorGreen, colorReset, name, colorGray, detail, colorReset)
}

func Fatal(format string, args ...any) {
	Err(format, args...)
	os.Exit(1)
}
