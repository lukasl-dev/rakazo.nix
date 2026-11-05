{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "rakazo-native";
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.default ];
    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
    services.rakazo = {
      enable = true;
      environmentFile = "/run/rakazo-test.env";
      screenProxySecretFile = "/run/rakazo-screen";
    };
    systemd.services.rakazo-test-secrets = {
      before = [
        "rakazo-api.service"
        "rakazo-worker.service"
        "rakazo-web.service"
        "rakazo-migrate.service"
      ];
      requiredBy = [
        "rakazo-api.service"
        "rakazo-worker.service"
        "rakazo-web.service"
        "rakazo-migrate.service"
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        umask 077
        cat > /run/rakazo-test.env <<'EOF'
        DATABASE_URL=postgresql://rakazo_runtime:synthetic-test-database-password@127.0.0.1:5432/rakazo
        BETTER_AUTH_SECRET=synthetic-auth-secret-for-local-vm-test-only-123456
        ENCRYPTION_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        SIGNUPS_ENABLED=true
        SANDBOX_PROVIDER=fake
        API_HOST=0.0.0.0
        EOF
        printf '%s' 'synthetic-screen-proxy-secret-for-vm-test-only-7890' > /run/rakazo-screen
      '';
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("rakazo-migrate.service", timeout=900)
    machine.wait_for_unit("rakazo-api.service")
    machine.wait_for_unit("rakazo-worker.service")
    machine.wait_for_unit("rakazo-web.service")
    machine.wait_until_succeeds("curl --fail http://127.0.0.1:3100/ready", timeout=180)
    machine.wait_until_succeeds("curl --fail http://127.0.0.1:5173/ | grep -q '<html'", timeout=180)
    machine.succeed("curl --fail http://127.0.0.1:5173/api/auth/get-session | jq -e '. == null'")
    machine.succeed("curl --fail http://127.0.0.1:3100/internal/health | jq -e '.sandbox == \"none\"'")
    machine.succeed("pid=$(systemctl show -p MainPID --value rakazo-api); tr '\\0' '\\n' < /proc/$pid/environ | grep -x SIGNUPS_ENABLED=false")
    machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: untrusted.invalid' http://127.0.0.1:5173/) = 403")
    machine.succeed("test -n \"$(ls /var/lib/rakazo-web/asset-archive/builds/*.json)\"")
    machine.wait_until_succeeds("journalctl -u rakazo-worker --no-pager | grep -q 'worker ready'", timeout=180)
    machine.succeed("test $(stat -c %a /var/lib/rakazo) = 700")
    machine.succeed("test $(stat -c %U /var/lib/rakazo) = rakazo-runtime")
    machine.fail("systemctl is-active docker.service")
    machine.fail("su -s /bin/sh rakazo-runtime -c 'cat /run/rakazo-test.env'")
    machine.fail("su -s /bin/sh rakazo-web -c 'ls /var/lib/rakazo'")
    machine.succeed("sudo -u postgres psql -Atc \"SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole FROM pg_roles WHERE rolname='rakazo_runtime'\" | grep -x t")
    machine.succeed("sudo -u postgres psql -d rakazo -Atc \"SELECT relrowsecurity AND relowner <> (SELECT oid FROM pg_roles WHERE rolname='rakazo_runtime') FROM pg_class WHERE oid='messages'::regclass\" | grep -x t")
    machine.succeed("systemctl restart rakazo-migrate.service")
    machine.succeed("systemctl restart rakazo-api.service rakazo-web.service")
    machine.wait_until_succeeds("curl --fail http://127.0.0.1:3100/ready")
    machine.succeed("systemctl stop rakazo-api.service")
    machine.succeed("sudo -u postgres psql -c 'ALTER ROLE rakazo_runtime BYPASSRLS'")
    machine.fail("systemctl start rakazo-api.service")
    machine.succeed("systemctl stop rakazo-api.service")
    machine.succeed("sudo -u postgres psql -c 'ALTER ROLE rakazo_runtime NOBYPASSRLS'")
    machine.succeed("systemctl reset-failed rakazo-api.service; systemctl start rakazo-api.service rakazo-web.service")
    machine.wait_until_succeeds("curl --fail http://127.0.0.1:3100/ready")
  '';
}
