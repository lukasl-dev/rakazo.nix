{
  stdenvNoCC,
  fetchurl,
  nodejs_24,
  makeWrapper,
}:

stdenvNoCC.mkDerivation {
  pname = "pnpm";
  version = "9.15.9";
  src = fetchurl {
    url = "https://registry.npmjs.org/pnpm/-/pnpm-9.15.9.tgz";
    hash = "sha256-z4anrXZEBjldQoam0J1zBxFyCsxtk+nc6ax6xNxKKKc=";
  };
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    mkdir -p "$out/libexec/pnpm" "$out/bin"
    cp -r . "$out/libexec/pnpm/"
    makeWrapper ${nodejs_24}/bin/node "$out/bin/pnpm" --add-flags "$out/libexec/pnpm/bin/pnpm.cjs"
  '';
  passthru = {
    majorVersion = "9";
    nodejs-slim = nodejs_24;
  };
}
