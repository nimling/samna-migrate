//go:build integration

package testdb

import "github.com/nimling/samna-migrate/internal/db"

// Ctx bundles the testdb plus disk paths the integration tests use.
type Ctx struct {
	D        *db.DB
	DBDir    string
	YAMLPath string
}
