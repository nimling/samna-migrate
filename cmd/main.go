package main

import (
	"fmt"
	"os"

	"github.com/nimling/samna-migrate/internal/migrate"
)

func main() {
	if err := migrate.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
