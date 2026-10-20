package log

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
)

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	orig := os.Stdout
	os.Stdout = w
	done := make(chan struct{})
	var buf bytes.Buffer
	go func() {
		_, _ = io.Copy(&buf, r)
		close(done)
	}()
	fn()
	w.Close()
	<-done
	os.Stdout = orig
	return buf.String()
}

func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	orig := os.Stderr
	os.Stderr = w
	done := make(chan struct{})
	var buf bytes.Buffer
	go func() {
		_, _ = io.Copy(&buf, r)
		close(done)
	}()
	fn()
	w.Close()
	<-done
	os.Stderr = orig
	return buf.String()
}

func forceColour(t *testing.T) {
	t.Helper()
	t.Setenv("NO_COLOR", "")
	t.Setenv("CLICOLOR", "")
	t.Setenv("TERM", "xterm")
	t.Setenv("CLICOLOR_FORCE", "1")
}

func TestNoColour(t *testing.T) {
	forceColour(t)
	t.Setenv("NO_COLOR", "1")
	out := captureStdout(t, func() { Success("done") })
	if out != "done\n" {
		t.Errorf("NO_COLOR output: %q", out)
	}
}

func TestPipeHasNoColour(t *testing.T) {
	forceColour(t)
	t.Setenv("CLICOLOR_FORCE", "")
	out := captureStderr(t, func() { Err("boom") })
	if out != "boom\n" {
		t.Errorf("piped output: %q", out)
	}
}

func TestInfo(t *testing.T) {
	forceColour(t)
	out := captureStdout(t, func() { Info("hello %s", "world") })
	if !strings.Contains(out, "hello world") {
		t.Errorf("Info missing message: %q", out)
	}
	if !strings.Contains(out, colorGray) {
		t.Errorf("Info missing gray prefix")
	}
}

func TestSuccess(t *testing.T) {
	forceColour(t)
	out := captureStdout(t, func() { Success("done") })
	if !strings.Contains(out, "done") {
		t.Errorf("Success missing message")
	}
	if !strings.Contains(out, colorGreen) {
		t.Errorf("Success missing green prefix")
	}
}

func TestWarn(t *testing.T) {
	forceColour(t)
	out := captureStdout(t, func() { Warn("careful") })
	if !strings.Contains(out, "careful") || !strings.Contains(out, colorYellow) {
		t.Errorf("Warn output: %q", out)
	}
}

func TestErr(t *testing.T) {
	forceColour(t)
	out := captureStderr(t, func() { Err("boom") })
	if !strings.Contains(out, "boom") || !strings.Contains(out, colorRed) {
		t.Errorf("Err output: %q", out)
	}
}

func TestHeader(t *testing.T) {
	forceColour(t)
	out := captureStdout(t, func() { Header("title") })
	if !strings.Contains(out, "title") || !strings.Contains(out, colorBold) || !strings.Contains(out, colorCyan) {
		t.Errorf("Header output: %q", out)
	}
}

func TestPlain(t *testing.T) {
	out := captureStdout(t, func() { Plain("just %d", 42) })
	if !strings.Contains(out, "just 42") {
		t.Errorf("Plain output: %q", out)
	}
}
