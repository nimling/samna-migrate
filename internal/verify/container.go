package verify

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"time"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
)

type container struct {
	Name string
	Port int
	Cfg  *config.Config
}

func startContainer(ctx context.Context, base *config.Config, image string) (*container, *db.DB, error) {
	if _, err := exec.LookPath("docker"); err != nil {
		return nil, nil, fmt.Errorf("docker not found in PATH")
	}
	port, err := freePort()
	if err != nil {
		return nil, nil, err
	}
	password := base.PGPassword
	if password == "" {
		password = "smigverify"
	}
	name := fmt.Sprintf("smig-verify-%d", time.Now().UnixNano())
	args := []string{
		"run", "--detach", "--rm", "--name", name,
		"--publish", fmt.Sprintf("127.0.0.1:%d:5432", port),
		"--env", "POSTGRES_USER=" + base.PGUser,
		"--env", "POSTGRES_PASSWORD=" + password,
		"--env", "POSTGRES_DB=" + base.PGDatabase,
		"--tmpfs", "/var/lib/postgresql/data",
		image,
	}
	if out, err := exec.CommandContext(ctx, "docker", args...).CombinedOutput(); err != nil {
		return nil, nil, fmt.Errorf("docker run: %v: %s", err, strings.TrimSpace(string(out)))
	}
	cfg := &config.Config{
		PGHost:     "127.0.0.1",
		PGPort:     fmt.Sprintf("%d", port),
		PGUser:     base.PGUser,
		PGPassword: password,
		PGDatabase: base.PGDatabase,
		PGSSLMode:  "disable",
	}
	deadline := time.Now().Add(90 * time.Second)
	for {
		cand, err := db.Open(ctx, cfg)
		if err == nil {
			return &container{Name: name, Port: port, Cfg: cfg}, cand, nil
		}
		if time.Now().After(deadline) {
			stopContainer(name)
			return nil, nil, fmt.Errorf("postgres container not ready after 90s: %w", err)
		}
		select {
		case <-ctx.Done():
			stopContainer(name)
			return nil, nil, ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

func stopContainer(name string) {
	exec.Command("docker", "rm", "-f", name).Run()
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	return port, nil
}

func imageForServer(ctx context.Context, d *db.DB) string {
	var v string
	if err := d.Pool.QueryRow(ctx, `SHOW server_version`).Scan(&v); err != nil {
		return "postgres:17"
	}
	major := strings.SplitN(strings.TrimSpace(v), ".", 2)[0]
	if major == "" {
		return "postgres:17"
	}
	return "postgres:" + major
}
