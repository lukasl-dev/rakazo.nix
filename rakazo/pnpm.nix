{
  lib,
  stdenvNoCC,
  fetchurl,
  nodejs_24,
  makeWrapper,
  autoPatchelfHook,
  stdenv,
}:

let
  version = "12.18.0";
  binaries = {
    x86_64-linux = {
      arch = "x64";
      hash = "sha256-Z53y7t8Vj2OdttHwDnE9dm0NevxqkxvFFJemJdHhvfc=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-LjJpMLm2cHEt8ck4SdclyF9riXzfkjnucktYfFDd1bw=";
    };
  };
  binary = binaries.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation {
  pname = "pnpm";
  inherit version;
  src = fetchurl {
    url = "https://registry.npmjs.org/pnpm/-/pnpm-${version}.tgz";
    hash = "sha256-KdHX2Zv27G0KPbsOxWVvDRbpl+i+Z2ykXFgdEctx91M=";
  };
  binarySrc = fetchurl {
    url = "https://registry.npmjs.org/@pnpm/exe.linux-${binary.arch}/-/exe.linux-${binary.arch}-${version}.tgz";
    inherit (binary) hash;
  };
  nativeBuildInputs = [
    makeWrapper
    autoPatchelfHook
  ];
  buildInputs = [ stdenv.cc.cc.lib ];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/pnpm" "$out/bin"
    cp -r . "$out/libexec/pnpm/"
    tar -xzf "$binarySrc" --strip-components=1 -C "$out/libexec/pnpm" package/pnpm
    tar -xOf "$binarySrc" package/THIRD-PARTY-NOTICES.md > "$out/libexec/pnpm/NATIVE-THIRD-PARTY-NOTICES.md"
    chmod +x "$out/libexec/pnpm/pnpm"
    makeWrapper "$out/libexec/pnpm/pnpm" "$out/bin/pnpm" \
      --prefix PATH : ${lib.makeBinPath [ nodejs_24 ]}
    runHook postInstall
  '';
  passthru = {
    majorVersion = "12";
    nodejs-slim = nodejs_24;
  };
}
