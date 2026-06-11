# 2. Static Secrets (KV v2)

Static secrets are the values *you* store in OpenBao and read back unchanged: a JWT signing key, SMTP credentials, an API token, even a database connection string. They're served by the **KV (key-value) secrets engine**.

## KV v1 vs KV v2 — use v2

| | KV v1 | KV v2 |
|---|---|---|
| Storage | Plain overwrite | Versioned |
| History | None — overwrite loses the old value | Keeps every version |
| Recovery | — | Soft-delete + undelete + rollback |

**Always use v2.** Versioning is the safety net: rotate a secret to a bad value and you can roll back to the previous version. It costs nothing extra.

## How values are organized

A KV secret is a **path** holding a bag of key-value pairs:

```
myapp/jwt   →  { "jwt_secret": "9f8b2c…(64 hex chars)" }
myapp/smtp  →  { "smtp_user": "mailer", "smtp_pass": "..." }
myapp/db    →  { "connection_string": "Server=...;User=app;Password=..." }
```

Seed them with the CLI (or the [bootstrap script](../scripts/openbao-bootstrap.sh)):

```bash
bao kv put myapp/jwt jwt_secret="$(openssl rand -hex 32)"
bao kv put myapp/smtp smtp_user=mailer smtp_pass='s3cr3t'
```

> **Tip:** store each value keyed by the exact name your framework's config expects (`Jwt:Secret` for .NET, `JWT_SECRET` for Node, etc.). Then "inject into config" is a straight copy — no remapping.

## The `/data/` quirk (the one thing that trips everyone)

KV v2's HTTP API silently inserts a `data/` segment into the path. You write and read the logical path `myapp/jwt`, but the *actual* API path is `myapp/data/jwt`.

- **In code:** every client library's `kv.v2` helper hides this — you pass `myapp` + `jwt`.
- **In ACL policies:** you must spell out the real path: `path "myapp/data/jwt" { capabilities = ["read"] }`.

If a read works but your policy denies access, this mismatch is almost always why.

## Reading them (the shape is the same everywhere)

```
client.kv.v2.read(path="jwt", mount="myapp")  →  { "jwt_secret": "..." }
```

Then overlay the result onto your framework's native config layer at startup. See your [recipe](../recipes/) for the idiomatic wiring; the [.NET recipe](../recipes/dotnet.md) shows the custom `IConfiguration` provider, which is the cleanest expression of "OpenBao as a config source."

## Read-once-at-boot, and what rotation means

Static secrets are read **once, at application startup**. That has a consequence worth stating plainly:

> **Rotating a static secret in OpenBao does not affect a running app until it restarts.**

This is fine — and usually desirable — for values like a JWT key you change rarely. The flow is: update the value in OpenBao → restart the app → new value is live. (Some integrations, like Spring Cloud Vault's `@RefreshScope`, can live-reload; most read-once. Don't add live-reload complexity unless you actually need it.)

If you store your **database connection string** as a static KV secret (a perfectly good choice for simpler apps), the same rule applies: change it in OpenBao, restart to pick it up. If you want credentials that rotate *without* restarts and expire on their own, that's the [dynamic database engine](03-dynamic-db-creds.md).

## What stays in plain config

OpenBao holds **secrets only**. Non-secret configuration — a JWT issuer/audience, an SMTP host/port, a feature flag — stays in your normal `appsettings.json` / `application.yml` / env. The OpenBao provider only overlays the sensitive keys. Keeping the split clean makes it obvious what's actually a secret.

---

**Next:** [Dynamic Database Credentials →](03-dynamic-db-creds.md)
