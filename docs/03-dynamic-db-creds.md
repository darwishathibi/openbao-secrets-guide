# 3. Dynamic Database Credentials

This is the advanced flex — and the part that genuinely changes your security posture. Instead of one standing database password, OpenBao **mints a fresh database user on demand**, leases it to your app, and **deletes it when the lease ends**.

## The mental model: vault vs vending machine

- **KV** (static): *you* put a password in, OpenBao hands the same one back.
- **Database engine** (dynamic): nobody stores an app password. The app asks "give me DB creds," and OpenBao runs `CREATE USER` on the spot, returns it with an expiry, and runs `DROP USER` when the time's up.

The credential doesn't exist until requested and stops existing shortly after.

## The pieces

**1. One privileged "management" connection** — the only standing DB credential.
OpenBao needs a database account that can `CREATE USER` / `DROP USER` / `GRANT`. You give it that once. **Only OpenBao holds it; the app never sees it.**

```bash
bao write database/config/myapp \
  plugin_name=mysql-database-plugin \
  connection_url="{{username}}:{{password}}@tcp(127.0.0.1:3306)/" \
  allowed_roles="myapp-role" \
  username="root" password="..."     # OpenBao's own privileged login
```

**2. A role** — the SQL templates plus the time limits.

```bash
bao write database/roles/myapp-role \
  db_name=myapp \
  creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; \
    GRANT SELECT,INSERT,UPDATE,DELETE ON \`myapp\`.* TO '{{name}}'@'%';" \
  revocation_statements="DROP USER '{{name}}'@'%';" \
  default_ttl="1h" max_ttl="24h"
```

`{{name}}` and `{{password}}` are placeholders OpenBao fills with random values on each request.

## The request → mint flow

```
App → read database/creds/myapp-role
        │
OpenBao ├─ generates random name:     v-approle-myapp-aB3xK9
        ├─ generates random password
        ├─ runs creation_statements against the DB (via its mgmt connection):
        │     CREATE USER 'v-approle-myapp-aB3xK9'@'%' IDENTIFIED BY '...';
        │     GRANT SELECT,INSERT,UPDATE,DELETE ON `myapp`.* ...
        │
        └─ returns: { username, password, lease_id, lease_duration: 3600 }
```

The app builds its DB connection from that username/password and connects as that freshly-created user. The database has no idea OpenBao exists — to it, that's just a normal login.

## The lease lifecycle

Every dynamic credential comes with a **lease** — a countdown timer with a handle (`lease_id`). The lease *is* how OpenBao tracks "this credential is alive; clean it up at T+ttl."

```
T+0      creds issued, lease_duration = 3600s
T+~2400  app renews the lease (before ~2/3 elapsed) → timer resets
T+...    renews again... up to max_ttl (24h)
T+max    can't extend further → OpenBao runs revocation_statements:
                DROP USER 'v-approle-myapp-aB3xK9'@'%';
         → credential is DEAD at the database level
```

Three ways a credential dies: **TTL expires** without renewal, **max_ttl reached** (can't renew → app must fetch fresh), or **explicit revoke** (app shutdown). The auto-`DROP` is the payoff: a leaked dynamic credential isn't valid "until you notice" — it's gone from the database within the lease window, automatically.

Your app needs a small background loop that renews before ~2/3 TTL and re-fetches at `max_ttl`. Every recipe shows this for its language.

## The connection-pool wrinkle (the real engineering)

Most ORMs fix a connection string at startup and pool connections under it. But your credential **rotates underneath you**. The resolution:

- Resolve the connection string **per new connection** from a small factory that reads the *current* cached creds — don't capture it once at startup.
- On rotation, the cache flips to new creds; **new** connections open with the new user. Existing pooled connections finish their work and drain naturally.
- OpenBao only `DROP`s the old user at lease end, after a grace window — so in-flight connections aren't cut off.

In .NET this means resolving the `DbContext` connection per-scope from the factory rather than the once-captured string. (See the [.NET recipe](../recipes/dotnet.md#4-advanced-dynamic-database-credentials).) Spring Cloud Vault does the lease renewal *and* datasource rotation for you — the least-effort dynamic story of the five.

## A migration footgun: who runs schema migrations?

If your app runs DB migrations at startup, note: the dynamic app role typically has **DML only** (`SELECT/INSERT/UPDATE/DELETE`), no DDL — so migrations fail. Two options:

- **(a)** give the bootstrap a second, elevated, short-lived role (`myapp-migrate`, DDL grants) used *only* for the migration step, then run normally on the DML role.
- **(b)** run migrations out-of-band in your deploy pipeline, so the app boots read-only-DDL.

Pick (a) to keep "app migrates itself on boot" behavior.

## When is this worth it?

Be honest — dynamic creds add real machinery (a server to run, leases to renew, the pool wrinkle). Reach for them when a **leaked DB password is expensive to contain**:

- Compliance/audit **mandates rotation** ("are DB creds rotated every 90 days?") — dynamic answers "automatically, hourly."
- **Many services or instances** share the DB — per-instance users let you trace and revoke one.
- **Broad operator access** to the deploy environment — many people could read a standing password.
- **High-value data at scale** — bigger blast radius justifies the tighter window.

For a small, single-operator app, **static KV is the right-sized choice.** Don't cargo-cult the complexity — adopt dynamic when the threat model calls for it, not because it's impressive.

---

**Next:** [Bootstrap, AppRole & "Secret Zero" →](04-bootstrap-approle.md)
