# 4. Bootstrap, AppRole & "Secret Zero"

Before any app can read a secret, OpenBao has to be *provisioned*: the engines enabled, the secrets seeded, an access policy written, and an AppRole created. This chapter covers doing that **reproducibly**, and the one secret you can never fully escape.

## Make it a script, not a checklist

Provisioning by hand is how environments drift. Capture it in an **idempotent script** ([scripts/openbao-bootstrap.sh](../scripts/openbao-bootstrap.sh)) — re-runnable, every step tolerant of "already exists," so the same script sets up your laptop and your production server. The script does five things:

1. Enable the **KV v2** engine.
2. Seed the **static secrets**.
3. Write a least-privilege **ACL policy**.
4. Enable **AppRole** and create the app's role.
5. (Optional) Enable the **database** engine + dynamic role.

## The ACL policy: least privilege, read-only

A policy is a list of paths and what you may do with them. The app only ever *reads* secrets and *renews* leases — nothing else:

```hcl
path "myapp/data/jwt"             { capabilities = ["read"] }
path "myapp/data/smtp"            { capabilities = ["read"] }
path "database/creds/myapp-role"  { capabilities = ["read"] }
path "sys/leases/renew"           { capabilities = ["update"] }
path "auth/token/renew-self"      { capabilities = ["update"] }
```

Note the `data/` segment in the KV paths — that's the [KV v2 quirk](02-static-secrets-kv.md#the-data-quirk-the-one-thing-that-trips-everyone) showing up where it actually matters. A policy without `data/` silently denies reads.

## AppRole and the two halves of identity

AppRole is the auth method for machines. It issues two values:

```bash
bao write auth/approle/role/myapp \
  token_policies="myapp-app" \
  token_ttl=1h token_max_ttl=4h

bao read   auth/approle/role/myapp/role-id     # → role_id
bao write -f auth/approle/role/myapp/secret-id # → secret_id
```

| | `role_id` | `secret_id` |
|---|---|---|
| What it is | A stable identifier for the role | A credential that proves "I'm allowed to assume this role" |
| Sensitivity | Low | **High — this is "secret zero"** |
| Lives where | App config / env (fine to commit a placeholder) | Runtime injection only — env var, mounted file, **never git** |

The app sends both, receives a **token**, and reads secrets with it.

## The bootstrap paradox — and how OpenBao shrinks it

There's an unavoidable truth: **to fetch secrets, you need a secret.** You can't make that disappear — but OpenBao shrinks it to exactly one value, the `secret_id`. Everything else (DB creds, JWT key, SMTP, API tokens) flows *from* it.

So "secret zero" is the irreducible floor. Your job is to protect that one value:

- **Locally:** a gitignored `.env` injected into the container.
- **In production:** an environment variable set by your deploy process, or a file mounted by your orchestrator — outside source control.
- **Never:** in `appsettings.json`, in a committed file, in a log line, or pasted into a chat.

Rotating it is cheap: generate a new `secret_id` (`bao write -f .../secret-id`) and redeploy. You can even cap its lifetime with `secret_id_ttl`.

## Feeding it to the app

The script ends by printing the `role_id` and `secret_id`. Wire them in per your framework:

```bash
# example: .NET local dev
dotnet user-secrets set "OpenBao:RoleId" "<role-id>"
dotnet user-secrets set "OpenBao:SecretId" "<secret-id>"
```

```bash
# example: anything env-based
export OPENBAO_ROLE_ID="<role-id>"
export OPENBAO_SECRET_ID="<secret-id>"
```

From here, the [recipe](../recipes/) for your stack takes over.

---

**Next:** [Dev vs Prod →](05-dev-vs-prod-sealing.md)
