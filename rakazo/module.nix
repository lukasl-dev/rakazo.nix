{ self }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.rakazo;
in
{
  options.services.rakazo = {
    enable = lib.mkEnableOption "Rakazo's native API, worker and web application";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.rakazo;
      defaultText = lib.literalExpression "inputs.rakazo.packages.\${pkgs.stdenv.hostPlatform.system}.rakazo";
      description = "Rakazo server package.";
    };
    publicUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:5173";
      example = "https://rakazo.example.org";
      description = "Public web origin, without a path or trailing slash. Use HTTPS outside local testing.";
    };
    environmentFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/secrets/rakazo.env";
      description = ''
        Root-readable systemd EnvironmentFile with DATABASE_URL (a restricted,
        password-authenticated runtime login), BETTER_AUTH_SECRET, ENCRYPTION_KEY,
        and optional provider credentials. Never put the database owner's URL here.
        The file is read at runtime, not copied to the Nix store.
      '';
    };
    screenProxySecretFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/secrets/rakazo-screen";
      description = "Runtime file containing a dedicated random secret of at least 32 characters, shared by API, worker and web. Not an EnvironmentFile.";
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        PI_DEFAULT_PROVIDER = "openai";
        PI_DEFAULT_MODEL = "gpt-5";
      };
      description = "Additional non-secret API and worker environment. Values are public in the Nix store; use environmentFile for credentials. Dedicated options take precedence.";
    };
    api = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "API listening address, reachable by the web service.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3100;
        description = "Internal API port.";
      };
    };
    web = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Web listening address.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5173;
        description = "Web port, including API and WebSocket proxying.";
      };
      allowedHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "localhost" ];
        description = "Hostnames accepted by the web server. Add the public hostname when using a reverse proxy.";
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Additional non-secret web-only environment, for example CSP settings.";
      };
    };
    worker.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the background worker for routines and reconciliation.";
    };
    sandboxProvider = lib.mkOption {
      type = lib.types.str;
      default = "none";
      example = "incus";
      description = "Upstream computer provider. none disables bot computers; other providers need their own configuration. This module never provisions Docker or sandbox infrastructure.";
    };
    signups = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow new account registration. Enable deliberately to create the first account.";
      };
      allowlist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "you@example.org" ];
        description = "Email addresses or @domains allowed to register when signups are enabled.";
      };
    };
    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create a local PostgreSQL database rakazo and a separate migration owner. DATABASE_URL must point to this database with a distinct runtime login and a password.";
      };
      migrate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run upstream schema, queue and runtime-role migrations before API and worker startup. Back up before upgrades; schema rollback is not automatic.";
      };
      migrationEnvironmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/run/secrets/rakazo-migrate.env";
        description = "Owner DATABASE_MIGRATION_URL for an external database. Passed only to the migration unit. Local databases use peer authentication instead.";
      };
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the web port only. Bind web.host to a reachable interface as well.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      let
        runtimePath = path: lib.hasPrefix "/" path && !lib.hasPrefix builtins.storeDir path;
      in
      [
        {
          assertion = runtimePath cfg.environmentFile;
          message = "services.rakazo.environmentFile must be an absolute runtime path outside the Nix store.";
        }
        {
          assertion = runtimePath cfg.screenProxySecretFile;
          message = "services.rakazo.screenProxySecretFile must be an absolute runtime path outside the Nix store.";
        }
        {
          assertion =
            cfg.database.migrationEnvironmentFile == null || runtimePath cfg.database.migrationEnvironmentFile;
          message = "services.rakazo.database.migrationEnvironmentFile must be an absolute runtime path outside the Nix store.";
        }
        {
          assertion = !cfg.database.createLocally || cfg.database.migrationEnvironmentFile == null;
          message = "Local Rakazo databases use peer authentication; do not set migrationEnvironmentFile.";
        }
        {
          assertion =
            !cfg.database.migrate
            || cfg.database.createLocally
            || cfg.database.migrationEnvironmentFile != null;
          message = "External Rakazo migrations require database.migrationEnvironmentFile with separate owner credentials.";
        }
        {
          assertion = cfg.api.port != cfg.web.port;
          message = "Rakazo API and web ports must differ.";
        }
        {
          assertion = builtins.match "https?://[^/?#]+" cfg.publicUrl != null;
          message = "services.rakazo.publicUrl must be an HTTP(S) origin without a path or trailing slash.";
        }
        {
          assertion =
            !(builtins.elem cfg.sandboxProvider [
              "docker"
              "fake"
            ]);
          message = "The native Rakazo module does not support Docker or test-only fake sandboxes.";
        }
        {
          assertion = !(cfg.environment ? DATABASE_MIGRATION_URL);
          message = "Keep DATABASE_MIGRATION_URL in database.migrationEnvironmentFile, never the runtime environment.";
        }
      ];

    environment.systemPackages = [ cfg.package ];
    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.web.port;

    users.groups = {
      rakazo-runtime = { };
      rakazo-web = { };
      rakazo = lib.mkIf cfg.database.migrate { };
    };
    users.users = {
      rakazo-runtime = {
        isSystemUser = true;
        group = "rakazo-runtime";
        home = "/var/lib/rakazo";
      };
      rakazo-web = {
        isSystemUser = true;
        group = "rakazo-web";
        home = "/var/lib/rakazo-web";
      };
      rakazo = lib.mkIf cfg.database.migrate {
        isSystemUser = true;
        group = "rakazo";
        home = "/var/lib/rakazo-migrate";
      };
    };

    systemd.services =
      let
        serviceDefaults = {
          StateDirectoryMode = "0700";
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          LockPersonality = true;
          Restart = "on-failure";
          RestartSec = 5;
          TimeoutStopSec = "50min";
        };

        managedEnvironment = {
          NODE_ENV = "production";
          DATA_DIR = "/var/lib/rakazo";
          HOME = "/var/lib/rakazo";
          API_HOST = cfg.api.host;
          API_PORT = toString cfg.api.port;
          API_URL = cfg.publicUrl;
          WEB_ORIGIN = cfg.publicUrl;
          BETTER_AUTH_URL = cfg.publicUrl;
          SANDBOX_PROVIDER = cfg.sandboxProvider;
          AGENT_RUNTIME = "pi";
          WAKEUP_DRIVER = "graphile";
          SIGNUPS_ENABLED = lib.boolToString cfg.signups.enable;
          SIGNUP_ALLOWLIST = lib.concatStringsSep "," cfg.signups.allowlist;
        };

        validate = "${
          pkgs.python3.withPackages (ps: [ ps.psycopg ])
        }/bin/python3 ${./check-environment.py} ${
          if cfg.database.createLocally then "local" else "external"
        }";

        appService =
          name:
          let
            dependencies =
              lib.optional cfg.database.createLocally "rakazo-database.service"
              ++ lib.optional cfg.database.migrate "rakazo-migrate.service";
          in
          {
            description = "Rakazo ${name}";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ] ++ dependencies;
            wants = [ "network-online.target" ];
            requires = dependencies;
            environment = cfg.environment // managedEnvironment;
            script = ''
              set -eu
              unset DATABASE_MIGRATION_URL
              ${lib.toShellVars managedEnvironment}
              export ${lib.concatStringsSep " " (builtins.attrNames managedEnvironment)}
              export SCREEN_PROXY_SECRET="$(cat "$CREDENTIALS_DIRECTORY/screen-proxy")"
              exec ${cfg.package}/bin/${name}
            '';
            serviceConfig = serviceDefaults // {
              User = "rakazo-runtime";
              Group = "rakazo-runtime";
              StateDirectory = "rakazo";
              WorkingDirectory = "/var/lib/rakazo";
              EnvironmentFile = cfg.environmentFile;
              LoadCredential = [ "screen-proxy:${cfg.screenProxySecretFile}" ];
              ExecStartPre = "${validate} runtime";
            };
          };
      in
      {
        rakazo-api = appService "rakazo-api";
        rakazo-worker = lib.mkIf cfg.worker.enable (appService "rakazo-worker");

        rakazo-web = {
          description = "Rakazo web application and proxy";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "rakazo-api.service"
          ];
          wants = [ "network-online.target" ];
          requires = [ "rakazo-api.service" ];
          environment = cfg.web.environment // {
            NODE_ENV = "production";
            HOME = "/var/lib/rakazo-web";
            WEB_HOST = cfg.web.host;
            WEB_PORT = toString cfg.web.port;
            API_PROXY_TARGET = "http://${
              if lib.hasInfix ":" cfg.api.host then "[${cfg.api.host}]" else cfg.api.host
            }:${toString cfg.api.port}";
            RAKAZO_ALLOWED_HOSTS = lib.concatStringsSep "," cfg.web.allowedHosts;
            RAKAZO_ASSET_ARCHIVE_DIR = "/var/lib/rakazo-web/asset-archive";
          };
          script = ''
            set -eu
            unset DATABASE_MIGRATION_URL
            mkdir -p "$RAKAZO_ASSET_ARCHIVE_DIR"
            export SCREEN_PROXY_SECRET="$(cat "$CREDENTIALS_DIRECTORY/screen-proxy")"
            exec ${cfg.package}/bin/rakazo-web
          '';
          serviceConfig = serviceDefaults // {
            User = "rakazo-web";
            Group = "rakazo-web";
            StateDirectory = "rakazo-web";
            WorkingDirectory = "/var/lib/rakazo-web";
            LoadCredential = [ "screen-proxy:${cfg.screenProxySecretFile}" ];
            TimeoutStopSec = "30s";
          };
        };

        rakazo-migrate = lib.mkIf cfg.database.migrate {
          description = "Migrate Rakazo database and provision restricted runtime role";
          after = [
            "network-online.target"
          ]
          ++ lib.optional cfg.database.createLocally "rakazo-database.service";
          wants = [ "network-online.target" ];
          requires = lib.optional cfg.database.createLocally "rakazo-database.service";
          environment =
            cfg.environment
            // managedEnvironment
            // {
              HOME = "/var/lib/rakazo-migrate";
              DATA_DIR = "/var/lib/rakazo-migrate";
            }
            // lib.optionalAttrs cfg.database.createLocally {
              DATABASE_MIGRATION_URL = "postgresql://rakazo@localhost/rakazo?host=/run/postgresql";
            };
          script = ''
            set -eu
            ${lib.optionalString cfg.database.createLocally ''
              export DATABASE_MIGRATION_URL='postgresql://rakazo@localhost/rakazo?host=/run/postgresql'
            ''}
            ${validate} migration
            ${cfg.package}/bin/rakazo-migrate
            ${validate} runtime
          '';
          serviceConfig = serviceDefaults // {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "rakazo";
            Group = "rakazo";
            StateDirectory = "rakazo-migrate";
            WorkingDirectory = "/var/lib/rakazo-migrate";
            EnvironmentFile = [
              cfg.environmentFile
            ]
            ++ lib.optional (
              cfg.database.migrationEnvironmentFile != null
            ) cfg.database.migrationEnvironmentFile;
            Restart = "no";
            TimeoutStartSec = "30min";
          };
        };

        rakazo-database = lib.mkIf cfg.database.createLocally {
          description = "Prepare Rakazo database role administration";
          after = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          requires = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "postgres";
            ExecStart = "${config.services.postgresql.package}/bin/psql --dbname=rakazo --set=ON_ERROR_STOP=1 --command='GRANT rakazo_app TO rakazo WITH ADMIN TRUE, INHERIT FALSE, SET FALSE'";
          };
        };
      };

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ "rakazo" ];
      ensureUsers = [
        {
          name = "rakazo";
          ensureDBOwnership = true;
          ensureClauses.createrole = true;
        }
        {
          name = "rakazo_app";
          ensureClauses.login = false;
        }
      ];
    };
  };
}
