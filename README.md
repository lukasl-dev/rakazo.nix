# rakazo.nix

Native [Rakazo](https://github.com/elie222/rakazo) packaging and a NixOS module. No Docker.

Provides the `rakazo` package, `nixosModules.default`, and an overlay exposing `pkgs.rakazo` for `x86_64-linux` and `aarch64-linux`.

```sh
nix build
nix develop
nix flake check
nix build .#docs-md
```

## NixOS

Add `rakazo.url = "github:lukasl-dev/rakazo.nix";` to your flake inputs:

```nix
{
  imports = [ inputs.rakazo.nixosModules.default ];

  services.rakazo = {
    enable = true;
    publicUrl = "https://rakazo.example.org";
    web.allowedHosts = [ "rakazo.example.org" ];
    environmentFile = "/run/secrets/rakazo.env";
    screenProxySecretFile = "/run/secrets/rakazo-screen";

    signups = {
      enable = true;
      allowlist = [ "you@example.org" ];
    };
  };
}
```

The module manages PostgreSQL, migrations, the API, worker and web server. Web listens on `127.0.0.1:5173`, API on `127.0.0.1:3100`; the firewall stays closed. Point your HTTPS reverse proxy at the **web port**, with WebSocket forwarding and response buffering disabled.

Signups are disabled by default. The example allows registration for one email address.

### Secrets

Provide a root-readable runtime environment file, outside the Nix store:

```dotenv
DATABASE_URL=postgresql://rakazo_runtime:REPLACE_WITH_PASSWORD@127.0.0.1:5432/rakazo
BETTER_AUTH_SECRET=REPLACE_WITH_AUTH_SECRET
ENCRYPTION_KEY=REPLACE_WITH_ENCRYPTION_KEY
```

Generate each value separately with `openssl rand -hex 32`. `screenProxySecretFile` contains a fourth random secret as plain text, not `NAME=value`.

Migrations create the `rakazo_runtime` login with restricted grants. Keep it separate from the database owner (`rakazo`); do not use `postgres` or `rakazo_app` as the runtime login.

### Configuration

Use `environment` for non-secret [upstream settings](https://github.com/elie222/rakazo/blob/main/docs/self-host-configuration.md) and `environmentFile` for provider credentials. Generate the full module option reference with `nix build .#docs-md`.

`sandboxProvider` defaults to `"none"`, disabling bot computers. Incus and remote providers need separately configured infrastructure. Model connections must also be configured separately.

For external PostgreSQL, set `database.createLocally = false` and supply `database.migrationEnvironmentFile` with the owner's `DATABASE_MIGRATION_URL`. Both database URLs must use the same TCP endpoint and database name, with routing in the URL rather than query parameters. Set `database.migrate = false` if you manage migrations elsewhere.

Back up PostgreSQL, `/var/lib/rakazo` and your keys before upgrades. NixOS rollback does not undo database migrations.

## Updating

```sh
nix run .#update          # latest stable release
nix run .#update -- v0.8.0
nix flake check
```

The updater refreshes the source and dependency hashes in `VERSION.json`. A release that changes pnpm versions also requires updating `rakazo/pnpm.nix`. The daily GitHub workflow builds and tests updates before committing and tagging them.
