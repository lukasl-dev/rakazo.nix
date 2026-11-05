{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPnpmDeps,
  callPackage,
  pnpmConfigHook,
  nodejs_24,
  makeWrapper,
  python3,
  fetchurl,
  runCommand,
  autoPatchelfHook,
  openssl,
  zlib,
}:

let
  metadata = builtins.fromJSON (builtins.readFile ../VERSION.json);
  pnpm = callPackage ./pnpm.nix { };
  enginePlatform =
    if stdenv.hostPlatform.isx86_64 then "debian-openssl-3.0.x" else "linux-arm64-openssl-3.0.x";
  runtimePath = lib.makeBinPath [
    nodejs_24
    pnpm
  ];
  schemaEngine =
    runCommand "rakazo-prisma-schema-engine"
      {
        src = fetchurl {
          url = "https://binaries.prisma.sh/all_commits/${metadata.prismaEngineRev}/${enginePlatform}/schema-engine.gz";
          hash = metadata.prismaEngineHashes.${stdenv.hostPlatform.system};
        };
        nativeBuildInputs = [ autoPatchelfHook ];
        buildInputs = [
          openssl
          zlib
          stdenv.cc.cc.lib
        ];
      }
      ''
        mkdir -p "$out/bin"
        gzip -dc "$src" > "$out/bin/schema-engine"
        chmod +x "$out/bin/schema-engine"
        autoPatchelf "$out"
      '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "rakazo";
  inherit (metadata) version;
  src = fetchFromGitHub {
    owner = "elie222";
    repo = "rakazo";
    inherit (metadata) rev hash;
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 3;
    hash = metadata.pnpmDepsHash;
  };

  nativeBuildInputs = [
    nodejs_24
    pnpm
    pnpmConfigHook
    makeWrapper
    python3
  ];

  postPatch = ''
    substituteInPlace apps/web/vite.config.ts \
      --replace-fail 'buildIdAt(new Date())' 'buildIdAt(new Date("${metadata.sourceDate}"))'
    substituteInPlace apps/web/src/asset-archive.ts \
      --replace-fail 'export const ASSET_ARCHIVE_DIR = "asset-archive";' \
        'export const ASSET_ARCHIVE_DIR = process.env.RAKAZO_ASSET_ARCHIVE_DIR ?? "asset-archive";'
  '';

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export PRISMA_SCHEMA_ENGINE_BINARY=${schemaEngine}/bin/schema-engine
    grep -Eq "@prisma/engines-version@[^']+\\.${metadata.prismaEngineRev}'" pnpm-lock.yaml
    pnpm --filter @rakazo/db generate
    pnpm --filter @rakazo/api --filter @rakazo/worker build
    RAKAZO_ALLOW_DEV_SECRETS=1 pnpm --filter @rakazo/web build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/rakazo" "$out/bin"
    cp -r . "$out/lib/rakazo/"
    for service in api worker; do
      makeWrapper ${nodejs_24}/bin/node "$out/bin/rakazo-$service" \
        --chdir "$out/lib/rakazo/apps/$service" \
        --add-flags "--enable-source-maps dist/index.js" \
        --prefix PATH : ${runtimePath}
    done
    makeWrapper ${nodejs_24}/bin/node "$out/bin/rakazo-migrate" \
      --chdir "$out/lib/rakazo/apps/api" \
      --add-flags "--enable-source-maps dist/cli/migrate-database.js" \
      --set PRISMA_SCHEMA_ENGINE_BINARY ${schemaEngine}/bin/schema-engine \
      --prefix PATH : ${runtimePath}
    makeWrapper ${nodejs_24}/bin/node "$out/bin/rakazo-web" \
      --chdir "$out/lib/rakazo/apps/web" \
      --run 'set -- --host "''${WEB_HOST:-127.0.0.1}" "$@"' \
      --add-flags "node_modules/vite/bin/vite.js preview --configLoader runner" \
      --prefix PATH : ${lib.makeBinPath [ nodejs_24 ]}
    runHook postInstall
  '';

  meta = {
    description = "Self-hosted AI assistant platform";
    homepage = "https://github.com/elie222/rakazo";
    license = lib.licenses.asl20;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "rakazo-api";
  };
})
