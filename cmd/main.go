package main

import (
	"os"

	"github.com/nimling/samna-migrate/internal/migrate"
)

func main() {
	os.Exit(migrate.Execute())
}
