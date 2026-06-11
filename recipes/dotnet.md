# .NET

How an ASP.NET Core app reads secrets from OpenBao using [VaultSharp](https://github.com/rajanadar/VaultSharp), surfacing them through the framework's own `IConfiguration` so the rest of your code is OpenBao-unaware.

## Prerequisites

```bash
dotnet add package VaultSharp
```

The app expects these (non-secret `RoleId` in config, secret `SecretId` from env/user-secrets):

```jsonc
// appsettings.json — non-secret knobs only
"OpenBao": {
  "Enabled": true,
  "Address": "http://127.0.0.1:8200",
  "RoleId": "<role-id from openbao-bootstrap.sh>"
}
```

```bash
# secret zero — never in appsettings/git
dotnet user-secrets set "OpenBao:SecretId" "<secret-id from bootstrap>"
```

## 1. AppRole login → token

VaultSharp performs the AppRole login for you when you construct the client — you just hand it the `role_id` + `secret_id`. The `secret_id` is "secret zero": the one irreducible secret everything else flows from.

```csharp
using VaultSharp;
using VaultSharp.V1.AuthMethods.AppRole;

var auth = new AppRoleAuthMethodInfo(roleId, secretId);
IVaultClient client = new VaultClient(new VaultClientSettings(address, auth));
// The token is fetched lazily on the first request and auto-renewed by VaultSharp.
```

## 2. Read a KV v2 secret

```csharp
// Logical path "jwt" lives under the "myapp" KV v2 mount.
var secret = await client.V1.Secrets.KeyValue.V2
    .ReadSecretAsync(path: "jwt", mountPoint: "myapp");

string jwtSecret = secret.Data.Data["jwt_secret"].ToString()!;
```

> **The KV v2 `/data/` quirk:** the raw HTTP API reads KV v2 at `myapp/data/jwt`, not `myapp/jwt` — the engine injects a `data/` segment. VaultSharp's `KeyValue.V2` helper hides this, so you pass the logical path `"jwt"`. You only see `data/` when writing ACL policies (`path "myapp/data/jwt"`).

## 3. Inject into native config

.NET's config home is `IConfiguration`. The idiomatic move is a **custom configuration provider** that reads OpenBao at startup and overlays the sensitive keys — so controllers, `JwtBearer`, EF Core, everything, read config exactly as they always have. OpenBao becomes invisible.

```csharp
// OpenBaoConfigurationProvider.cs
using Microsoft.Extensions.Configuration;

public sealed class OpenBaoConfigurationProvider(OpenBaoOptions options, IVaultClient client)
    : ConfigurationProvider
{
    // Each logical path's data is keyed by the exact config key your app reads.
    private static readonly string[] Paths = ["jwt", "smtp"];

    public override void Load()
    {
        if (!options.Enabled) return;

        var data = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in Paths)
        {
            // Config providers load synchronously at boot.
            var secret = client.V1.Secrets.KeyValue.V2
                .ReadSecretAsync(path, mountPoint: options.KvMount).GetAwaiter().GetResult();
            foreach (var kv in secret.Data.Data)
                data[kv.Key] = kv.Value?.ToString();
        }
        Data = data;
    }
}

public sealed class OpenBaoConfigurationSource(OpenBaoOptions options, IVaultClient client)
    : IConfigurationSource
{
    public IConfigurationProvider Build(IConfigurationBuilder builder)
        => new OpenBaoConfigurationProvider(options, client);
}
```

Store secrets in OpenBao keyed by the config key the app already uses — e.g. KV path `myapp/jwt` holds `{ "Jwt:Secret": "..." }`. Then register the source **before** anything reads config:

```csharp
// Program.cs
var builder = WebApplication.CreateBuilder(args);

var openBao = builder.Configuration.GetSection("OpenBao").Get<OpenBaoOptions>() ?? new();
if (openBao.Enabled)
{
    var auth = new AppRoleAuthMethodInfo(openBao.RoleId, openBao.SecretId);
    var client = new VaultClient(new VaultClientSettings(openBao.Address, auth));

    // ConfigurationManager implements Add(IConfigurationSource) EXPLICITLY — cast to reach it,
    // otherwise the compiler binds the Add<TSource>(Action<TSource>) extension and fails inference.
    ((IConfigurationBuilder)builder.Configuration)
        .Add(new OpenBaoConfigurationSource(openBao, client));
}

// From here on, nothing knows OpenBao exists:
var jwtKey = builder.Configuration["Jwt:Secret"];   // came from OpenBao
```

> Use a `record` for `OpenBaoOptions` (init-only props) so tests can do `options with { Enabled = false }`. Non-positional records bind fine via `Configuration.Get<T>()`.

## 4. (Advanced) Dynamic database credentials

```csharp
using VaultSharp.V1.SecretsEngines.Database;

var creds = await client.V1.Secrets.Database
    .GetCredentialsAsync("myapp-role", databaseMountPoint: "database");

string user = creds.Data.Username;          // e.g. v-approle-myapp-a8f3...
string pass = creds.Data.Password;          // random, short-lived
string leaseId = creds.LeaseId;
int ttl = creds.LeaseDurationSeconds;       // e.g. 3600
```

Build your connection string from `user`/`pass`. The catch unique to .NET: **EF Core fixes its connection string at DI registration and pools under it, but dynamic creds rotate.** Resolve the connection string *per-scope* from a small factory that reads the current cached creds, and run a `BackgroundService` that renews the lease before ~2/3 TTL (`client.V1.System.RenewLeaseAsync`) and re-fetches fresh creds at `max_ttl`. New connections pick up rotated creds; old pooled ones drain; OpenBao `DROP`s the expired user at lease end. See [docs/03](../docs/03-dynamic-db-creds.md) for the full lifecycle.

## Native config home

`IConfiguration`. A custom `ConfigurationProvider` overlays OpenBao secrets onto it at boot, so the entire app — DI, `JwtBearer`, EF Core — reads config with no awareness of OpenBao.

## Gotchas

- **The `/data/` path quirk** — `KeyValue.V2` hides it in code, but ACL policy paths must say `myapp/data/jwt`.
- **Read once at boot** — the provider's `Load()` runs at startup. Rotating a static secret in OpenBao needs an app restart (`JwtBearer` also caches its validation params). Live-reload via `IOptionsMonitor` is a later concern.
- **Keep the flag** — gating on `OpenBao:Enabled` (default `false`) lets tests and non-OpenBao environments run on plain config, making this a safe, additive retrofit.
- **Never log or commit the `secret_id`** — it's secret zero. Env var or user-secrets only.
