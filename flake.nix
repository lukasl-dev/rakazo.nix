{
  description = "Native Rakazo package and NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake = {
        overlays.default = final: _: {
          rakazo = final.callPackage ./rakazo/package.nix { };
        };
        nixosModules.default = import ./rakazo/module.nix { inherit self; };
        nixosModules.rakazo = self.nixosModules.default;
      };

      perSystem =
        { pkgs, system, ... }:
        let
          rakazo = pkgs.callPackage ./rakazo/package.nix { };
          python = pkgs.python3.withPackages (ps: [ ps.psycopg ]);
          update = import ./update.nix { inherit pkgs; };
        in
        {
          packages = {
            inherit rakazo;
            default = rakazo;
            docs-md =
              let
                instance = nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [ self.nixosModules.default ];
                };
                docs = pkgs.nixosOptionsDoc { options.services.rakazo = instance.options.services.rakazo; };
              in
              pkgs.runCommand "rakazo-options" { } ''
                mkdir -p $out
                cp ${docs.optionsCommonMark} $out/index.md
              '';
          };
          apps.update = {
            type = "app";
            program = "${update}/bin/rakazo-update";
            meta.description = "Update the pinned Rakazo release and dependency hashes";
          };
          checks = {
            package = rakazo;
            module = import ./tests/module.nix { inherit pkgs self; };
            service = import ./tests/service.nix { inherit pkgs self; };
            tooling =
              pkgs.runCommand "rakazo-tooling-check"
                {
                  nativeBuildInputs = [
                    python
                    pkgs.basedpyright
                    pkgs.gitMinimal
                    pkgs.jq
                    pkgs.bash
                    pkgs.actionlint
                    pkgs.shellcheck
                  ];
                }
                ''
                  export HOME="$TMPDIR/home"
                  export PYTHONDONTWRITEBYTECODE=1
                  mkdir -p "$HOME"
                  cp -R ${./.} source
                  chmod -R u+w source
                  cd source
                  basedpyright --pythonpath ${python}/bin/python
                  python tests/environment.py
                  python tests/publication.py
                  actionlint
                  shellcheck .github/scripts/publish-update.sh
                  touch $out
                '';
            updater = update;
          };
          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt
              pkgs.basedpyright
              python
              pkgs.actionlint
              pkgs.shellcheck
              pkgs.gh
            ];
            PYTHONDONTWRITEBYTECODE = "1";
          };
          formatter = pkgs.nixfmt;
        };
    };
}
