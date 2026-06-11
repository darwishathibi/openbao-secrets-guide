# Node.js / Express

How an Express app authenticates to OpenBao with AppRole and loads its secrets into a frozen config object at boot.

## Prerequisites

```bash
npm i node-vault
```

The app expects these environment variables:

```bash
OPENBAO_ADDR=http://127.0.0.1:8200
OPENBAO_ROLE_ID=<the-approle-role-id>
OPENBAO_SECRET_ID=<the-approle-secret-id>
```

`OPENBAO_ROLE_ID` is non-secret and stable (think of it as a username). `OPENBAO_SECRET_ID` is the sensitive half — it should be delivered to the workload at runtime, never committed.

All examples use CommonJS, OpenBao at `http://127.0.0.1:8200`, KV mount `myapp`, and AppRole mount `approle`.

## 1. AppRole login → token

AppRole exchanges a `role_id` + `secret_id` pair for a short-lived client token. Every subsequent API call uses that token.

```js
// vault.js
const vault = require('node-vault');

const OPENBAO_ADDR = process.env.OPENBAO_ADDR || 'http://127.0.0.1:8200';

// Create an unauthenticated client (no token yet).
const client = vault({
  apiVersion: 'v1',
  endpoint: OPENBAO_ADDR,
});

async function login() {
  const role_id = process.env.OPENBAO_ROLE_ID;
  const secret_id = process.env.OPENBAO_SECRET_ID;

  if (!role_id || !secret_id) {
    throw new Error('OPENBAO_ROLE_ID and OPENBAO_SECRET_ID must be set');
  }

  // POST auth/approle/login → { auth: { client_token, lease_duration, ... } }
  const result = await client.approleLogin({ role_id, secret_id });

  // node-vault stores the token on the client for subsequent calls.
  client.token = result.auth.client_token;

  return client;
}

module.exports = { client, login };
```

The `secret_id` is **"secret zero"**: the one credential the app must possess to bootstrap everything else. Protect it accordingly — inject it via the orchestrator's secret mechanism, keep it out of logs and source control, and prefer short, single-use secret-ids where your deployment allows.

## 2. Read a KV v2 secret

We store the app's JWT signing key at logical path `myapp/jwt`, under key `jwt_secret`.

```js
async function readJwtSecret(client) {
  // Logical path is `myapp/jwt`; see the /data/ note below.
  const res = await client.read('myapp/data/jwt');
  return res.data.data.jwt_secret;
}
```

### The KV v2 `/data/` path quirk

KV **version 2** is a versioned engine. The HTTP API does not read your logical path directly — it injects a `data/` segment after the mount. So the logical secret `myapp/jwt` is actually read at:

```
myapp/data/jwt
```

and the response is double-nested: the actual key/values live under `res.data.data`, while `res.data.metadata` holds version info.

`node-vault` is a thin wrapper over the raw API, so **you supply the `data/` segment yourself** (as above). If you forget it, you'll get a 404 against what looks like the right path. (KV v1 has no `data/` segment — `myapp/jwt` is read as-is.) A small helper keeps call sites clean:

```js
// Read a KV v2 secret by its logical path, returning the inner data object.
async function readKv2(client, mount, path) {
  const res = await client.read(`${mount}/data/${path}`);
  return res.data.data;
}

// const { jwt_secret } = await readKv2(client, 'myapp', 'jwt');
```

## 3. Inject into native config

Node has no built-in config layer, so the idiomatic "config home" is a plain object frozen at startup. You fetch every static secret once, build the object, freeze it, and the rest of the app imports from it. Nothing reads OpenBao on the hot path.

```js
// config.js
const { client, login } = require('./vault');

let config = null;

async function loadSecrets() {
  await login();

  const res = await client.read('myapp/data/jwt');
  const { jwt_secret } = res.data.data;

  config = Object.freeze({
    port: Number(process.env.PORT) || 3000,
    jwtSecret: jwt_secret,
    nodeEnv: process.env.NODE_ENV || 'development',
  });

  // Optional: also expose to libraries that only read process.env.
  process.env.JWT_SECRET = jwt_secret;

  return config;
}

function getConfig() {
  if (!config) throw new Error('loadSecrets() has not completed');
  return config;
}

module.exports = { loadSecrets, getConfig };
```

Wire it so secrets are loaded **before** the server accepts traffic — `await loadSecrets()` then `app.listen()`:

```js
// server.js
const express = require('express');
const { loadSecrets, getConfig } = require('./config');

async function main() {
  // Fetch and freeze all static secrets up front.
  await loadSecrets();
  const config = getConfig();

  const app = express();

  app.get('/health', (_req, res) => res.json({ ok: true }));

  app.get('/token', (_req, res) => {
    // config.jwtSecret is available synchronously everywhere downstream.
    res.json({ alg: 'HS256', hasSecret: Boolean(config.jwtSecret) });
  });

  app.listen(config.port, () => {
    console.log(`listening on :${config.port}`);
  });
}

main().catch((err) => {
  console.error('startup failed:', err.message);
  process.exit(1);
});
```

Static secrets are read **once at boot**. There is no automatic refresh — to pick up a rotated value, restart the process (or re-run `loadSecrets()` deliberately).

## 4. (Advanced) Dynamic database credentials

For databases, OpenBao can mint **short-lived, per-instance credentials** on demand instead of handing out one long-lived password. Reading `database/creds/myapp-role` returns a fresh `{ username, password }` plus a lease describing how long it lives.

```js
const { Pool } = require('pg');

async function buildDbPool(client) {
  // GET database/creds/myapp-role
  const res = await client.read('database/creds/myapp-role');
  const { username, password } = res.data;
  const { lease_id, lease_duration } = res; // seconds

  const pool = new Pool({
    host: process.env.DB_HOST || '127.0.0.1',
    port: Number(process.env.DB_PORT) || 5432,
    database: process.env.DB_NAME || 'myapp',
    user: username,
    password,
    max: 10,
  });

  // Renew the lease at ~2/3 of its TTL so the credential never expires under us.
  const renewMs = Math.floor(lease_duration * (2 / 3)) * 1000;
  const timer = setInterval(async () => {
    try {
      await client.write('sys/leases/renew', { lease_id, increment: lease_duration });
    } catch (err) {
      console.error('lease renewal failed:', err.message);
      // On repeated failure, fetch new creds and rebuild the pool.
    }
  }, renewMs);
  timer.unref(); // don't keep the event loop alive on this alone

  return pool;
}
```

A dynamic credential is bound to its lease: renew it before the TTL elapses (the `setInterval` above), and OpenBao **auto-revokes** the database user the moment the lease ends — whether it expired or the process died. That bounded blast radius is the whole point of dynamic secrets.

## Native config home

Node has no built-in config layer; `process.env` plus a frozen config object loaded at boot is the convention.

## Gotchas

- **KV v2 needs `/data/`.** The logical path `myapp/jwt` is read at `myapp/data/jwt`, and values are nested under `res.data.data`. Forgetting the segment yields a confusing 404. KV v1 does not have this.
- **Static secrets are read once at boot.** Rotating a value in OpenBao does not affect a running process — restart (or re-run `loadSecrets()`) to pick up the new value.
- **Never log the secret-id.** It is secret zero. Keep `OPENBAO_SECRET_ID` out of logs, error messages, crash dumps, and source control; prefer short-lived, single-use secret-ids.
- **In-memory dev OpenBao wipes on restart.** A `bao server -dev` instance loses all mounts, policies, and secrets when it stops. Re-seed your KV data, AppRole, and database role each time you start a fresh dev server.
