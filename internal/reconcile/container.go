package reconcile

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

func startContainer(ctx context.Context, base *config.Config, image, prefix string) (*container, *db.DB, error) {
	if _, err := exec.LookPath("docker"); err != nil {
		return nil, nil, fmt.Errorf("docker not found in PATH")
	}
	port, err := freePort()
	if err != nil {
		return nil, nil, err
	}
	password := base.PGPassword
	if password == "" {
		password = "smigreconcile"
	}
	name := fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
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

func imageMajor(base string) string {
	_, tag, _ := strings.Cut(base, ":")
	tag = strings.TrimPrefix(tag, "pg")
	i := 0
	for i < len(tag) && tag[i] >= '0' && tag[i] <= '9' {
		i++
	}
	if i == 0 {
		return "17"
	}
	return tag[:i]
}

func pgtapImage(ctx context.Context, base string) (string, error) {
	major := imageMajor(base)
	image := "smig-pgtap:" + major
	if exec.CommandContext(ctx, "docker", "image", "inspect", image).Run() == nil {
		return image, nil
	}
	dockerfile := "FROM " + base + "\n" +
		"RUN apt-get update && apt-get install -y --no-install-recommends postgresql-" + major + "-pgtap && rm -rf /var/lib/apt/lists/*\n"
	build := exec.CommandContext(ctx, "docker", "build", "--tag", image, "-")
	build.Stdin = strings.NewReader(dockerfile)
	if out, err := build.CombinedOutput(); err != nil {
		return "", fmt.Errorf("docker build %s from %s: %v: %s", image, base, err, strings.TrimSpace(string(out)))
	}
	return image, nil
}

func stopContainer(name string) {
	exec.Command("docker", "rm", "-f", name).Run()
}

func DockerPresent() bool {
	_, err := exec.LookPath("docker")
	return err == nil
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
