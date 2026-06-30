package config

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

type Config struct {
	PGHost     string
	PGPort     string
	PGUser     string
	PGPassword string
	PGDatabase string
	PGSSLMode  string
	StepsFile  string
	DBDir      string
}

func FromEnv() *Config {
	return &Config{
		PGHost:     os.Getenv("PGHOST"),
		PGPort:     getenv("PGPORT", "5432"),
		PGUser:     getenv("PGUSER", "postgres"),
		PGPassword: os.Getenv("PGPASSWORD"),
		PGDatabase: os.Getenv("PGDATABASE"),
		PGSSLMode:  getenv("PGSSLMODE", "disable"),
		StepsFile:  getenv("MIGRATE_SCHEMA", "./database/migrate.yml"),
		DBDir:      getenv("DB_DIR", "./database"),
	}
}

func (c *Config) Validate() error {
	missing := []string{}
	if c.PGUser == "" {
		missing = append(missing, "PGUSER")
	}
	if c.PGDatabase == "" {
		missing = append(missing, "PGDATABASE")
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing required database configuration: %s", strings.Join(missing, ", "))
	}
	return nil
}

func (c *Config) ConnString() string {
	return fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=%s",
		c.PGHost, c.PGPort, c.PGUser, c.PGPassword, c.PGDatabase, c.PGSSLMode)
}

func LoadDotEnv(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx := strings.Index(line, "=")
		if idx < 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		val := strings.TrimSpace(line[idx+1:])
		val = strings.Trim(val, `"'`)
		if v, ok := os.LookupEnv(key); !ok || v == "" {
			os.Setenv(key, val)
		}
	}
	return scanner.Err()
}

func getenv(key, def string) string {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	return v
}
