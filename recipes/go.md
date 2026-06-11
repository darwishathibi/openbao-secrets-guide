# Go

This recipe shows how a Go application authenticates to OpenBao with AppRole and consumes static (KV v2) and dynamic (database) secrets using the official Vault API client, which is wire-compatible with OpenBao.

## Prerequisites

Install the client and the AppRole auth helper:

```bash
go get github.com/hashicorp/vault/api
go get github.com/hashicorp/vault/api/auth/approle
```

> The native-branded equivalent is `github.com/openbao/openbao/api`. The HashiCorp client is API-compatible with OpenBao and is used throughout this guide.

Export the connection and AppRole credentials:

```bash
export OPENBAO_ADDR=http://127.0.0.1:8200
export OPENBAO_ROLE_ID=...      # the role's stable identifier
export OPENBAO_SECRET_ID=...    # "secret zero" — treat like a password
```

## 1. AppRole login → token

AppRole exchanges a `role_id` (stable, like a username) and a `secret_id` (the credential you must protect — your "secret zero") for a short-lived OpenBao token. The client stores the returned token internally and attaches it to every subsequent request.

```go
package bao

import (
	"context"
	"fmt"
	"os"

	"github.com/hashicorp/vault/api"
	auth "github.com/hashicorp/vault/api/auth/approle"
)

// NewClient creates an OpenBao client and performs an AppRole login.
func NewClient(ctx context.Context) (*api.Client, error) {
	cfg := api.DefaultConfig()
	cfg.Address = os.Getenv("OPENBAO_ADDR") // e.g. http://127.0.0.1:8200

	client, err := api.NewClient(cfg)
	if err != nil {
		return nil, fmt.Errorf("create client: %w", err)
	}

	roleID := os.Getenv("OPENBAO_ROLE_ID")
	secretID := os.Getenv("OPENBAO_SECRET_ID")
	if roleID == "" || secretID == "" {
		return nil, fmt.Errorf("OPENBAO_ROLE_ID and OPENBAO_SECRET_ID must be set")
	}

	appRoleAuth, err := auth.NewAppRoleAuth(
		roleID,
		&auth.SecretID{FromString: secretID},
		// auth.WithMountPath("approle"), // default; override if mounted elsewhere
	)
	if err != nil {
		return nil, fmt.Errorf("build approle auth: %w", err)
	}

	authInfo, err := client.Auth().Login(ctx, appRoleAuth)
	if err != nil {
		return nil, fmt.Errorf("approle login: %w", err)
	}
	if authInfo == nil {
		return nil, fmt.Errorf("approle login returned no auth info")
	}

	return client, nil
}
```

`Login` sets the token on the client, so you do not call `client.SetToken` yourself. `SecretID` also supports `FromFile` and `FromEnv` if you prefer to keep the value out of process arguments.

## 2. Read a KV v2 secret

KV version 2 stores data under a hidden `/data/` segment and wraps the payload in metadata. The `KVv2` helper rewrites the path and unwraps the response for you, so you read logical paths (`myapp/jwt`) and get the values back directly.

```go
// ReadJWTSecret fetches the "jwt_secret" field from myapp/jwt (KV v2).
func ReadJWTSecret(ctx context.Context, client *api.Client) (string, error) {
	secret, err := client.KVv2("myapp").Get(ctx, "jwt")
	if err != nil {
		return "", fmt.Errorf("read myapp/jwt: %w", err)
	}

	raw, ok := secret.Data["jwt_secret"]
	if !ok {
		return "", fmt.Errorf("field jwt_secret missing in myapp/jwt")
	}

	jwt, ok := raw.(string)
	if !ok {
		return "", fmt.Errorf("jwt_secret is not a string")
	}
	return jwt, nil
}
```

Without the helper you would have to spell out the `/data/` path and reach into the nested map yourself:

```go
// Equivalent low-level form — note the literal "myapp/data/jwt".
secret, err := client.Logical().ReadWithContext(ctx, "myapp/data/jwt")
// values then live under secret.Data["data"].(map[string]interface{})["jwt_secret"]
```

Prefer `KVv2` for KV v2 mounts; reserve `Logical()` for engines that have no typed helper.

## 3. Inject into native config

Go has no built-in config layer. The convention is a typed `Config` struct populated once at startup, before any business code runs. Secrets fetched from OpenBao are loaded into that struct so the rest of the app depends only on plain fields, not on the client.

```go
package config

import (
	"context"
	"fmt"

	"example.com/myapp/bao"
)

type Config struct {
	JWTSecret string
	// ... other non-secret fields (ports, feature flags) populated from
	// flags/env/Viper can sit alongside the secrets here.
}

// Load builds the fully populated config at boot. Static secrets are read
// ONCE here; the running app never re-reads them.
func Load(ctx context.Context) (*Config, error) {
	client, err := bao.NewClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("openbao auth: %w", err)
	}

	jwt, err := bao.ReadJWTSecret(ctx, client)
	if err != nil {
		return nil, fmt.Errorf("load jwt secret: %w", err)
	}

	return &Config{JWTSecret: jwt}, nil
}
```

If you use Viper for the rest of your configuration, treat OpenBao as just another source: load files/env via Viper, then overlay the secret fields from the client into the same struct. Either way, resolve everything before constructing your handlers so a missing secret fails fast at startup.

## 4. (Advanced) Dynamic database credentials

The database secrets engine mints short-lived, per-request credentials on demand. Each read returns a fresh username/password plus a lease; when the lease expires OpenBao automatically revokes the database user.

```go
package db

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/hashicorp/vault/api"
	_ "github.com/lib/pq"
)

// OpenDB reads dynamic credentials and opens a *sql.DB with them.
func OpenDB(ctx context.Context, client *api.Client) (*sql.DB, *api.Secret, error) {
	secret, err := client.Logical().ReadWithContext(ctx, "database/creds/myapp-role")
	if err != nil {
		return nil, nil, fmt.Errorf("read dynamic db creds: %w", err)
	}
	if secret == nil || secret.Data == nil {
		return nil, nil, fmt.Errorf("no credentials returned for myapp-role")
	}

	username, _ := secret.Data["username"].(string)
	password, _ := secret.Data["password"].(string)
	if username == "" || password == "" {
		return nil, nil, fmt.Errorf("incomplete credentials in lease response")
	}

	// secret.LeaseID / secret.LeaseDuration describe the credential's lifetime.
	dsn := fmt.Sprintf(
		"postgres://%s:%s@127.0.0.1:5432/myapp?sslmode=disable",
		username, password,
	)
	pool, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, nil, fmt.Errorf("open db: %w", err)
	}
	return pool, secret, nil
}

// renewLease keeps the lease alive. Renew before ~2/3 of the TTL elapses so a
// failed renewal still leaves time to react. Run this in its own goroutine.
func renewLease(ctx context.Context, client *api.Client, secret *api.Secret) {
	ttl := time.Duration(secret.LeaseDuration) * time.Second
	ticker := time.NewTicker(ttl * 2 / 3)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// increment = how many more seconds you want; capped by max_ttl.
			if _, err := client.Sys().Renew(secret.LeaseID, secret.LeaseDuration); err != nil {
				// On failure the lease will expire and OpenBao auto-revokes the
				// user — fetch a fresh lease and reconnect.
				return
			}
		}
	}
}
```

When the lease ends (renewal stops or `max_ttl` is hit) OpenBao revokes the database user automatically, so leaked credentials are short-lived by design. For production, prefer the client's `LifetimeWatcher` (`client.NewLifetimeWatcher`) over a hand-rolled ticker — it handles backoff and non-renewable leases for you.

## Native config home

Go has no built-in config layer; a typed struct (optionally Viper) loaded at boot is the convention.

## Gotchas

- **KV v2 `/data/` path quirk** — the physical path is `myapp/data/jwt`, not `myapp/jwt`. Use `client.KVv2(mount)` so the helper inserts `/data/` and unwraps the metadata; only drop to `Logical()` when no typed helper exists.
- **Static secrets are read once** — `config.Load` runs at boot, so rotating a KV value in OpenBao does not reach a running process. Restart (or add an explicit reload path) to pick up changes; for hands-off rotation use dynamic secrets instead.
- **Never log the secret-id** — it is your "secret zero". Keep it out of logs, error messages, command-line arguments, and crash dumps; prefer `SecretID{FromFile: ...}` or `FromEnv` over passing it as a flag.
- **Dev-mode OpenBao is in-memory** — `bao server -dev` is unsealed, uses an HTTP listener, and loses all data on restart. It is for local experiments only; never point a real app at it.
