# Python / FastAPI

How a FastAPI service authenticates to OpenBao with AppRole and pulls its secrets into a Pydantic settings object at startup, using the [`hvac`](https://hvac.readthedocs.io/) client.

## Prerequisites

```bash
pip install hvac pydantic-settings
```

OpenBao speaks the same HTTP API as HashiCorp Vault, so `hvac` works unchanged against it.

Environment the app expects:

```bash
export OPENBAO_ADDR=http://127.0.0.1:8200
export OPENBAO_ROLE_ID=<your-role-id>
export OPENBAO_SECRET_ID=<your-secret-id>
```

Conventions used throughout: OpenBao at `http://127.0.0.1:8200`, KV v2 mounted at `myapp`, AppRole mounted at `approle`.

## 1. AppRole login → token

AppRole exchanges a `role_id` (public, bakeable into config) plus a `secret_id` (sensitive, short-lived, delivered out-of-band) for a Vault token. The `secret_id` is your **"secret zero"** — the one bootstrap credential the app must receive securely (CI injector, orchestrator, init container). Everything else is derived from the token you get back, so protect it accordingly and never log it.

```python
import os
import hvac


def openbao_client() -> hvac.Client:
    client = hvac.Client(url=os.environ["OPENBAO_ADDR"])

    client.auth.approle.login(
        role_id=os.environ["OPENBAO_ROLE_ID"],
        secret_id=os.environ["OPENBAO_SECRET_ID"],
    )

    if not client.is_authenticated():
        raise RuntimeError("OpenBao AppRole login failed")

    return client
```

`login()` stores the returned token on the client, so subsequent calls are authenticated automatically.

## 2. Read a KV v2 secret

KV version 2 keeps versioned history, so the storage path is not the same as the logical path: a secret you wrote to `myapp/jwt` actually lives at `myapp/data/jwt` on the raw API, with the payload nested under `data.data`. The `kv.v2` helper inserts that `/data/` segment for you — pass the **logical** path (`jwt`) and the `mount_point`, not the raw one.

```python
def read_jwt_secret(client: hvac.Client) -> str:
    resp = client.secrets.kv.v2.read_secret_version(
        path="jwt",
        mount_point="myapp",
        raise_on_deleted_version=True,
    )
    # resp["data"]["data"] is your actual key/value map
    return resp["data"]["data"]["jwt_secret"]
```

The double `data` is not a typo: the outer `data` is the API envelope, the inner `data` is the KV v2 secret body.

## 3. Inject into native config

In Python the idiomatic config home is a Pydantic `BaseSettings` class. It already reads env vars and `.env` files; we overlay the OpenBao-sourced values onto the same object at startup so the rest of the app depends on one typed settings object and never talks to OpenBao directly.

```python
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Non-secret config from env / .env
    app_name: str = "myapp"
    database_url: str = ""

    # Populated from OpenBao at startup (default empty, never committed)
    jwt_secret: str = ""


settings = Settings()
```

Wire the load into the FastAPI lifespan so secrets are present **before** any route runs. Static secrets are read **once** at boot — this is a deliberate trade-off: it is simple and fast, but rotating the secret requires a restart (see Gotchas).

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = openbao_client()
    settings.jwt_secret = read_jwt_secret(client)
    # Stash the authenticated client if later stages need it (e.g. dynamic creds)
    app.state.openbao = client
    yield
    # Nothing to tear down for static secrets


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, bool]:
    # settings.jwt_secret is guaranteed populated here
    return {"jwt_loaded": bool(settings.jwt_secret)}
```

Routes import `settings` and read `settings.jwt_secret`; they have no idea OpenBao exists.

## 4. (Advanced) Dynamic database credentials

For databases, prefer short-lived credentials minted on demand over a static password. OpenBao's database secrets engine creates a fresh DB user per request and auto-revokes it when the lease ends.

```python
from sqlalchemy.ext.asyncio import create_async_engine, AsyncEngine


def db_engine_from_openbao(client: hvac.Client) -> tuple[AsyncEngine, str]:
    creds = client.secrets.database.generate_credentials(
        name="myapp-role",
        mount_point="database",
    )["data"]

    username = creds["username"]
    password = creds["password"]
    # creds also carries lease_id and lease_duration (TTL in seconds)

    url = f"postgresql+asyncpg://{username}:{password}@127.0.0.1:5432/myapp"
    engine = create_async_engine(url, pool_pre_ping=True)
    return engine, creds["lease_id"]
```

Leases are time-bound. Renew **before** roughly 2/3 of the TTL elapses to keep the same credential alive:

```python
client.sys.renew_lease(lease_id=lease_id, increment=3600)
```

If you let the lease expire, OpenBao auto-revokes the DB user and open connections start failing — so either renew on a background task or rebuild the engine with fresh credentials before that point. Keep renewal logic minimal; for many apps, fetching new creds on restart is enough.

## Native config home

Pydantic `BaseSettings` is the idiomatic config layer; overlay OpenBao values onto it at startup.

## Gotchas

- **KV v2 `/data/` path quirk.** The raw API path is `myapp/data/jwt` and the payload nests under `data.data`. Use the `client.secrets.kv.v2` helpers and pass the logical path (`jwt`) + `mount_point` so you don't hand-build the path or unwrap the wrong layer.
- **Read-once means restart-to-rotate.** Static secrets loaded at boot are cached for the process lifetime. Rotating the value in OpenBao does nothing until you restart (or build an explicit re-read path). Pick this consciously.
- **Never log the secret-id.** It is secret zero — keep it out of logs, tracebacks, and crash reporters. Read it from the environment and don't echo it back. The same goes for the token and any minted DB password.
- **Dev-mode OpenBao is in-memory.** `bao server -dev` stores everything in RAM with a throwaway root token; restarting wipes all secrets and unseals automatically. Great for this guide, never for anything real.
