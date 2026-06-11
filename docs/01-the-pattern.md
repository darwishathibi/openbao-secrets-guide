# 1. The Pattern

Every framework in this guide integrates with OpenBao the same way. Learn this once and the recipes become fill-in-the-blanks.

## The problem it solves

Your app needs secrets: a JWT signing key, an SMTP password, a database connection string. The default home for these is a `.env` file or environment variables. The trouble with that:

- **They leak and stay valid.** A connection string in a stack trace, a `.env` in a screenshot — the credential is good until *you* notice and manually rotate it. That could be never.
- **Rotation is scary and manual**, so nobody does it.
- **There's no access control or audit** — anyone who can read the deploy environment has every secret, and nothing records who read what.

OpenBao centralizes secrets into one access-controlled, versioned, audited store, and — for databases — can issue **short-lived credentials that auto-expire**.

## The four steps

```
①  Authenticate    App → AppRole login (role_id + secret_id) → OpenBao token
②  Read static     App → read KV v2 (jwt, smtp, ...)         → values
③  Read dynamic    App → read database/creds/<role>          → fresh DB user (advanced)
④  Inject          Values → the framework's native config    → app reads config as normal
```

**Steps ② and ③ are identical in every language** — they're just HTTP calls to OpenBao, wrapped by a client library. **Steps ① and ④ are the only real differences:** how each framework does the AppRole login, and where its "native config" lives.

That's the whole insight. A `.NET` `IConfiguration` provider, a Node frozen-config object, a Pydantic `Settings`, a Spring `Environment`, a Go struct — they're all just "step ④" for their ecosystem.

## Why authenticate with AppRole?

OpenBao needs to know *who's asking* before it hands over secrets. **AppRole** is the auth method built for applications (as opposed to humans). It splits the identity in two:

| Piece | Sensitivity | Lives where |
|---|---|---|
| `role_id` | Low — it's just an identifier | App config / env (non-secret) |
| `secret_id` | **High — "secret zero"** | Injected at runtime: env var, mounted file, never in git |

The app sends both, gets back a short-lived **token**, and uses that token for every subsequent read. This is the bootstrap paradox in its smallest form: you can't get secrets without *a* secret, but OpenBao shrinks that to exactly one `secret_id`. Everything else — DB creds, JWT key, SMTP — flows *from* it. See [docs/04](04-bootstrap-approle.md).

## Why the secrets stay behind your config layer

The design goal is **isolation**: the OpenBao integration should be the *only* code that knows OpenBao exists. The rest of your app keeps reading `config["Jwt:Secret"]` / `process.env.JWT_SECRET` / `settings.jwt_secret` exactly as before.

You achieve that by making OpenBao a **source** for your existing config system, not a thing your business logic calls. Swap the source, change nothing else. The payoff:

- You can turn OpenBao **off** with a flag and fall back to plain env/config — which is exactly how you keep tests and local-without-OpenBao working.
- Adopting OpenBao is **additive**: no controller, service, or query changes.
- Migrating *away* (or to a different secrets backend) touches one integration module, not your whole codebase.

## Static vs dynamic, in one breath

- **Static (KV v2):** values you put in OpenBao — JWT key, SMTP creds. Read once at boot. Centralized and controlled, but the value itself is long-lived. → [docs/02](02-static-secrets-kv.md)
- **Dynamic (database engine):** OpenBao *generates* a fresh DB user per request, leased and auto-deleted. No standing DB password exists. → [docs/03](03-dynamic-db-creds.md)

Start with static — it's the right size for most apps. Reach for dynamic when a leaked DB credential is genuinely expensive to contain.

---

**Next:** [Static Secrets (KV v2) →](02-static-secrets-kv.md)
