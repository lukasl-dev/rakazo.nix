{ pkgs, self }:
let
  inherit (pkgs) lib;
  evaluate =
    settings:
    (self.inputs.nixpkgs.lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        self.nixosModules.default
        {
          services.rakazo = {
            environmentFile = "/run/rakazo.env";
            screenProxySecretFile = "/run/screen";
          }
          // settings;
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/vda";
            fsType = "ext4";
          };
          system.stateVersion = "26.05";
        }
      ];
    }).config;
  local = evaluate { enable = true; };
  external = evaluate {
    enable = true;
    database = {
      createLocally = false;
      migrationEnvironmentFile = "/run/owner.env";
    };
    worker.enable = false;
    openFirewall = true;
  };
  disabled = evaluate { enable = false; };
  valid = c: builtins.all (a: a.assertion) c.assertions;
in
assert valid local;
assert valid external;
assert !(disabled.systemd.services ? rakazo-api);
assert !(external.systemd.services ? rakazo-worker);
assert !external.services.postgresql.enable;
assert local.services.postgresql.enable;
assert local.systemd.services.rakazo-api.environment.SANDBOX_PROVIDER == "none";
assert local.systemd.services.rakazo-api.environment.SIGNUPS_ENABLED == "false";
assert
  local.systemd.services.rakazo-web.serviceConfig.User
  != local.systemd.services.rakazo-api.serviceConfig.User;
assert !(local.systemd.services.rakazo-web.serviceConfig ? EnvironmentFile);
assert !(local.systemd.services.rakazo-api.environment ? DATABASE_MIGRATION_URL);
assert builtins.elem "rakazo-migrate.service" local.systemd.services.rakazo-api.requires;
assert external.networking.firewall.allowedTCPPorts == [ 5173 ];
assert
  !(valid (evaluate {
    enable = true;
    environmentFile = "/nix/store/secret";
  }));
assert
  !(valid (evaluate {
    enable = true;
    sandboxProvider = "docker";
  }));
assert
  !(valid (evaluate {
    enable = true;
    database.createLocally = false;
  }));
pkgs.runCommand "rakazo-module-check" { } "touch $out"
