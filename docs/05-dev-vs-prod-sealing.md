# 5. Dev vs Prod

The same OpenBao integration code runs in both environments — but how OpenBao itself is *run* differs sharply. Getting this wrong is how you either can't develop locally or leak your entire vault in production.

## The two topologies

| | Local (dev-mode) | Production |
|---|---|---|
| Command | `bao server -dev` | `bao server -config=...` |
| Seal | Auto-unsealed | **Sealed on boot — manual unseal** |
| Storage | In-memory (disposable) | **Raft (integrated), persistent + backed up** |
| Root token | Fixed (`dev-root-token`) | Real init; stored offline, break-glass only |
| Data on restart | **Wiped** | Survives |

## Dev-mode: convenient and disposable

```bash
docker run --cap-add=IPC_LOCK \
  -e BAO_DEV_ROOT_TOKEN_ID=dev-root-token \
  -p 8200:8200 openbao/openbao:latest \
  server -dev -dev-listen-address=0.0.0.0:8200
```

Dev-mode is auto-unsealed, in-memory, with a fixed root token. Perfect for local work — run the [bootstrap script](../scripts/openbao-bootstrap.sh), wire up your app, done.

> ⚠️ **In-memory means `docker rm` wipes everything** — your seeded secrets *and* the AppRole `role_id`/`secret_id`. Recovery is: start a fresh container → re-run the bootstrap → re-fetch role-id/secret-id → re-set them in your app. This is a feature (disposable, reproducible), not a bug. **Never use dev-mode for anything real.**

## Production: sealed by default

A production OpenBao boots **sealed**: its storage is encrypted and it can't read its own data — including your app's secrets — until it's **unsealed**. Unsealing reconstructs the master key from key shares.

The canonical method is **Shamir's Secret Sharing**: at `bao operator init`, OpenBao splits the unseal key into N shares (e.g. 5) with a threshold (e.g. 3). Unsealing requires any 3 of the 5. This means no single person can unseal alone — the shares are distributed to different people/locations.

```bash
bao operator init -key-shares=5 -key-threshold=3
# → 5 unseal keys + an initial root token. Store each separately.
```

Use **Raft (integrated) storage** so data persists and can be backed up — no external storage dependency.

## The unseal runbook

After any restart of the OpenBao host, it comes up sealed and your app can't fetch secrets until someone unseals it:

```bash
bao status                 # Sealed: true
bao operator unseal        # paste share 1
bao operator unseal        # paste share 2
bao operator unseal        # paste share 3
bao status                 # Sealed: false
# then restart/redeploy the app so it re-runs its startup secret fetch
```

Keep a short runbook in your ops docs so whoever's on call can do this at 3am.

## 🚩 Anti-patterns that defeat the point

- **Never auto-unseal by stashing the unseal keys in a script on the same host.** The keys and the thing they protect must not co-locate — one leaked file would unseal everything. (Cloud KMS auto-unseal is the legitimate automated option, at the cost of a cloud dependency.)
- **Never store all Shamir shares together.** Distribute them — that's the entire point of splitting.
- **Never commit the `secret_id`, root token, or unseal keys.** Secret zero and the master keys live outside git, always.
- **Don't run dev-mode in production** "just to get started." Dev-mode has no persistence and a known root token — it's a vault with the door removed.

## What carries over, what doesn't

Your **application code is identical** in both environments — same recipe, same AppRole login, same config injection. What changes is purely operational: where OpenBao stores data, whether it auto-unseals, and how you protect the keys. That clean separation — app code unaware, ops handles topology — is the goal.

---

**Back to:** [README](../README.md) · [The Pattern](01-the-pattern.md)
