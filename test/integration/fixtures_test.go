//go:build integration

package integration

import "os"

func osMkdir(dir string) error {
	return os.MkdirAll(dir, 0o755)
}

func osWrite(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o644)
}
