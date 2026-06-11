# Spring Boot (Java)

This recipe shows how a Spring Boot 3.x application consumes secrets from OpenBao using **Spring Cloud Vault**, which turns OpenBao secrets into native Spring `Environment` properties.

## Prerequisites

OpenBao is Vault-API compatible, so the Spring Cloud Vault starter works against it unchanged.

**Maven:**

```xml
<dependency>
  <groupId>org.springframework.cloud</groupId>
  <artifactId>spring-cloud-starter-vault-config</artifactId>
</dependency>
```

Manage the version via the Spring Cloud BOM in `dependencyManagement` (e.g. `spring-cloud-dependencies` 2023.x for Spring Boot 3.2+).

**Gradle:**

```groovy
implementation 'org.springframework.cloud:spring-cloud-starter-vault-config'
```

**`application.yml` knobs:**

```yaml
spring:
  application:
    name: myapp
  config:
    import: vault://        # required in Spring Boot 3.x (see Gotchas)
  cloud:
    vault:
      uri: http://127.0.0.1:8200
      authentication: APPROLE
      app-role:
        role-id: ${VAULT_ROLE_ID}
        secret-id: ${VAULT_SECRET_ID}
        role: myapp                 # AppRole role name (optional if role-id is enough)
        app-role-path: approle      # AppRole auth mount
```

Provide the role-id/secret-id via environment variables (never hard-code them):

```bash
export VAULT_ROLE_ID="..."     # from: bao read auth/approle/role/myapp/role-id
export VAULT_SECRET_ID="..."   # from: bao write -f auth/approle/role/myapp/secret-id
```

## 1. AppRole login → token

With Spring Cloud Vault this step is **declarative**. You configure the AppRole credentials and Spring performs the login, exchanges them for a Vault token, and transparently renews it. You never write login code.

```yaml
spring:
  cloud:
    vault:
      authentication: APPROLE
      app-role:
        role-id: ${VAULT_ROLE_ID}
        secret-id: ${VAULT_SECRET_ID}
        app-role-path: approle
```

The `role-id` is a non-sensitive identifier, but the **`secret-id` is "secret zero"** — the one credential that bootstraps access to every other secret. Inject it from the environment, a Kubernetes secret, or a CI/CD secret store; it must never live in source control or a baked image.

**Imperative equivalent** (for apps not using the starter — e.g. plain `spring-vault-core`):

```java
VaultEndpoint endpoint = VaultEndpoint.create("127.0.0.1", 8200);
endpoint.setScheme("http");

AppRoleAuthenticationOptions options = AppRoleAuthenticationOptions.builder()
    .roleId(RoleId.provided(System.getenv("VAULT_ROLE_ID")))
    .secretId(SecretId.provided(System.getenv("VAULT_SECRET_ID")))
    .path("approle")
    .build();

VaultTemplate vault = new VaultTemplate(
    endpoint,
    new AppRoleAuthentication(options, new RestTemplate()));
```

## 2. Read a KV v2 secret

With Spring Cloud Vault, enable the KV backend and point it at your mount. Secrets stored at `myapp/<app-name>` are loaded automatically as properties at startup.

```yaml
spring:
  cloud:
    vault:
      kv:
        enabled: true
        backend: myapp        # KV mount
        backend-version: 2     # KV v2
        default-context: ${spring.application.name}   # -> myapp/myapp
```

Given a secret written with:

```bash
bao kv put myapp/myapp jwt.secret=s3cr3t db.url=jdbc:postgresql://...
```

…those keys become Spring properties `jwt.secret` and `db.url` with no further code. The KV v2 **`/data/` path quirk** (where reads/writes go through `myapp/data/myapp` under the hood) is handled by the starter when `backend-version: 2` is set — you address the logical path `myapp/myapp`.

**Imperative equivalent** — read `myapp/jwt` returning `jwt_secret`:

```java
VaultKeyValueOperations kv =
    vault.opsForKeyValue("myapp", KeyValueBackend.KV_2);

VaultResponseSupport<Map<String, Object>> response = kv.get("jwt");
String jwtSecret = (String) response.getData().get("jwt_secret");
```

## 3. Inject into native config

This is the Spring-idiomatic home for secrets: once Spring Cloud Vault has loaded them, **OpenBao secrets are just normal Spring properties**. Consume them exactly as you would any value from `application.yml`.

**`@Value`:**

```java
@Component
public class TokenService {

    private final String jwtSecret;

    public TokenService(@Value("${jwt.secret}") String jwtSecret) {
        this.jwtSecret = jwtSecret;
    }
}
```

**`@ConfigurationProperties`** (preferred for grouped, typed config):

```java
@ConfigurationProperties(prefix = "jwt")
public record JwtProperties(String secret, Duration ttl) {}
```

```java
@SpringBootApplication
@ConfigurationPropertiesScan
public class Application { /* ... */ }
```

Unlike the read-once-at-boot story in most frameworks, Spring Cloud Vault can **refresh secrets at runtime**: annotate a bean with `@RefreshScope` and POST to the `/actuator/refresh` endpoint (or rely on lease-renewal callbacks) to re-read changed secrets without a restart.

```java
@RefreshScope
@Component
public class TokenService { /* re-instantiated on refresh */ }
```

## 4. (Advanced) Dynamic database credentials

Spring Cloud Vault has a **first-class `database` secret backend integration**. Instead of a static password, OpenBao mints a short-lived database user per application instance, and Spring injects it directly into `spring.datasource.username` / `spring.datasource.password` — then **auto-renews the lease** for you.

```yaml
spring:
  cloud:
    vault:
      database:
        enabled: true
        role: myapp-role           # DB role configured in OpenBao
        backend: database          # database secrets mount
        username-property: spring.datasource.username
        password-property: spring.datasource.password
```

With this in place your `DataSource` is configured from credentials that did not exist before the app started and that expire shortly after it stops. The big selling point: **Spring owns the entire lease lifecycle** — acquisition, renewal, and rotation — so there is no static DB password anywhere in your config or deployment.

The imperative path also exists (`vault.read("database/creds/myapp-role")` via `VaultTemplate`), but you would then have to manage lease renewal yourself; the starter is strongly preferred here.

## Native config home

Spring `Environment` / `@Value` / `@ConfigurationProperties`; Spring Cloud Vault makes OpenBao secrets first-class Spring properties.

## Gotchas

- **Context bootstrapping.** In Spring Boot 3.x, Vault property sources are loaded via `spring.config.import: vault://` in `application.yml`. If you prefer the legacy bootstrap context, add `spring-cloud-starter-bootstrap` and use `bootstrap.yml` instead — but pick one; mixing them causes properties to resolve too late or not at all.
- **KV v2 `/data/` path.** KV v2 stores secrets under `<mount>/data/<path>` and wraps values in a `data` envelope. The starter handles this when `backend-version: 2` is set, so you address the logical path (`myapp/myapp`), not the physical `/data/` path — but a wrong `backend-version` is a common silent failure.
- **Never commit `secret-id`.** The AppRole `secret-id` is secret zero. Keep it in env vars / Kubernetes secrets / your CI secret store, never in `application.yml`, git, or a container image layer.
- **Dev-mode OpenBao is in-memory.** `bao server -dev` keeps everything in memory with a fixed root token and unseals automatically. It is for local development only — all secrets vanish on restart, and it must never be used in production.
