# rakazo.nix

[Rakazo](https://github.com/elie222/rakazo), packaged natively for Nix and NixOS.
Flake-parts, a pinned upstream release, an overlay, NixOS service options, and a
scheduled GitHub Actions updater. No Docker daemon, images, or Compose deployment.

## Package

```sh
nix build .#rakazo
```

The package contains the API, background worker, web application and migration
command. The web service includes upstream's API and screen proxy middleware;
serving the static assets alone is not equivalent.

Linux outputs: `x86_64-linux` and `aarch64-linux`. Exported interfaces:

- `packages.<system>.rakazo` (also `default`)
- `overlays.default`, adding `pkgs.rakazo`
- `nixosModules.rakazo` (also `default`)
- `apps.<system>.update`
- `packages.<system>.docs-md`, generated module option reference

## NixOS

Add `github:lukasl-dev/rakazo.nix` as a flake input, then:

```nix
{
  imports = [ inputs.rakazo.nixosModules.default ];

  services.rakazo = {
    enable = true;
    publicUrl = "https://rakazo.example.org";
    web.allowedHosts = [ "rakazo.example.org" ];
    environmentFile = "/run/secrets/rakazo.env";
    screenProxySecretFile = "/run/secrets/rakazo-screen";

    # Enable deliberately for initial registration; restrict who can register.
    signups = {
      enable = true;
      allowlist = [ "you@example.org" ];
    };
  };

  services.nginx = {
    enable = true;
    virtualHosts."rakazo.example.org" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:5173";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          proxy_read_timeout 3600s;
          client_max_body_size 50m;
        '';
      };
    };
  };
  # Configure security.acme and open ports 80/443 separately.
}
```

Provision the two secret files using your secret manager, **outside the Nix
store**. Do not use `builtins.toFile` or plaintext Nix strings for their contents.
The root-readable `rakazo.env` uses systemd EnvironmentFile syntax:

```dotenv
DATABASE_URL=postgresql://rakazo_runtime:REPLACE_WITH_RANDOM_HEX_PASSWORD@127.0.0.1:5432/rakazo
BETTER_AUTH_SECRET=REPLACE_WITH_RANDOM_HEX_SECRET
ENCRYPTION_KEY=REPLACE_WITH_RANDOM_HEX_KEY
```

Generate each value independently, for example with `openssl rand -hex 32`.
`rakazo-screen` contains a fourth independent random secret as plain text, not
`NAME=value`. It is delivered through systemd credentials; the web process does
not receive the database, authentication or encryption credentials.

The default local database setup creates PostgreSQL database `rakazo`. A separate
OS/database owner runs upstream migrations through peer authentication. Migrations
create the password-authenticated runtime login from `DATABASE_URL` and assign its
restricted grants. Keep that login distinct from `rakazo`, `rakazo_app` and
`postgres`; `rakazo_runtime` in the example is suitable. The API and worker never
need the owner's credentials. This deployment reserves those database role names
and supports one instance per host.

The API binds `127.0.0.1:3100`, web binds `127.0.0.1:5173`, and neither firewall
port is opened by default. Proxy to **web**, not directly to API. For LAN-only
testing, change `publicUrl`, `web.host`, `web.allowedHosts`, and optionally
`openFirewall` (opens only the web port). Use HTTPS for normal use.

### Configuration

Main options under `services.rakazo`:

| Option | Default | Purpose |
| --- | --- | --- |
| `package` | Flake package | Override the packaged release |
| `publicUrl` | `http://localhost:5173` | Public authentication and web origin |
| `api.host`, `api.port` | `127.0.0.1`, `3100` | Internal API listener |
| `web.host`, `web.port` | `127.0.0.1`, `5173` | Web listener |
| `web.allowedHosts` | `[ "localhost" ]` | Accepted web hostnames |
| `worker.enable` | `true` | Background routines and reconciliation |
| `signups.enable` | `false` | New account registration |
| `signups.allowlist` | `[]` | Registration email/domain allowlist |
| `sandboxProvider` | `"none"` | Computer provider; no computers by default |
| `database.createLocally` | `true` | Manage local PostgreSQL database and roles |
| `database.migrate` | `true` | Migrate before starting API and worker |
| `database.migrationEnvironmentFile` | `null` | External owner credentials, migration-only |
| `environment` | `{}` | Additional non-secret API/worker environment |
| `web.environment` | `{}` | Additional non-secret web configuration |
| `openFirewall` | `false` | Open the web port |

For an external PostgreSQL database, disable `database.createLocally`, set the
runtime `DATABASE_URL`, and supply a separate root-readable
`database.migrationEnvironmentFile` containing `DATABASE_MIGRATION_URL`. Provision
an owner capable of running upstream migrations and creating/granting the runtime
roles; see upstream's [database role documentation](https://github.com/elie222/rakazo/blob/v0.8.0/docs/self-host-configuration.md#database-roles).
Both URLs must use the same TCP database endpoint and database name; distinct
migration/pooler endpoints and query-parameter routing are not supported by this
initial module. Startup checks reject privileged runtime roles and table owners.

For other features, use upstream environment names in `environment`, and put
their secrets in `environmentFile`. Dedicated options are enforced by the service
launcher; other EnvironmentFile values override `environment` entries.
AI runs require a configured model connection, local or hosted. Model provider
credentials, email delivery and remote sandbox accounts are not created by this
module.

**No Docker does not mean an unrestricted local agent shell.** `sandboxProvider =
"none"` disables provisioned bot computers. Incus or supported remote providers
require separately configured infrastructure and credentials; this flake does not
build or manage their computer images. Docker and test-only fake sandboxes are
rejected by the module.

## Operations

Services: `rakazo-api`, `rakazo-worker`, `rakazo-web`, `rakazo-migrate` and, with a
local database, `rakazo-database`. Inspect them with `systemctl` and `journalctl`.

Back up PostgreSQL **as the owner**, `/var/lib/rakazo`, and the encryption and
authentication keys together. The web service has its own `/var/lib/rakazo-web`
state. Losing encryption keys can make stored content unrecoverable. Database
migrations run during service upgrades; a NixOS generation rollback does **not**
undo schema changes. Take backups before upgrading. Workers may take up to 50
minutes to drain on stop, matching upstream's production grace period.

## Updates and checks

```sh
nix run .#update          # latest stable upstream release
nix run .#update -- v0.8.0
nix flake check
```

The updater resolves a release to its commit and regenerates the source, pnpm and
platform-specific Prisma engine hashes in `VERSION.json`. The pinned commit date
provides a deterministic web build ID. It works in a temporary copy and only
replaces metadata after dependency fetching succeeds. It does not commit, push,
activate services, or update `flake.lock`. Build-related compatibility changes
still require review when upstream changes its toolchain.

The scheduled/manual update workflow checks the resulting package and service
before committing metadata and publishing a version tag. Publication rejects
unexpected changed paths and a moved default-branch base. CI also checks pushes
and pull requests. This automation only runs once the files are committed and
pushed; no workflow dispatch is needed for local development.

### Verification and current limits

Verified locally on x86_64-linux: package build, strict Python type checking,
module evaluation, tooling tests, isolated updater regeneration and idempotence,
and a NixOS VM covering migrations, restricted roles, API/worker/web startup,
proxying, host filtering, asset archival, restarts and rejection of an RLS-bypass
runtime role. aarch64-linux is evaluated, not built.

This initial package retains the full upstream workspace and dependencies
(roughly 3.3 GiB). Real model calls, browser-driven account flows, email, external
databases, sandbox providers and production upgrades have not been validated.
The module does not promise isolation for arbitrary agent-installed code or MCP
commands; systemd service hardening is not a replacement for a computer sandbox.
