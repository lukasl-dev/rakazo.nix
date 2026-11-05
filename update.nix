{ pkgs }:
pkgs.writeShellApplication {
  name = "rakazo-update";
  runtimeInputs = [
    pkgs.gh
    pkgs.gitMinimal
    pkgs.jq
    pkgs.nix
    pkgs.gnutar
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
  ];
  text = ''
    root="$(git rev-parse --show-toplevel)"
    cd "$root"
    test -f rakazo/package.nix
    tag="''${1:-$(gh api repos/elie222/rakazo/releases/latest --jq .tag_name)}"
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Expected a stable Rakazo release tag, got: $tag" >&2
      exit 1
    fi
    commit="$(gh api "repos/elie222/rakazo/commits/$tag")"
    rev="$(jq -er .sha <<< "$commit")"
    source_date="$(jq -er .commit.committer.date <<< "$commit")"
    [[ "$rev" =~ ^[0-9a-f]{40}$ ]]
    if [[ "$(jq -r .rev VERSION.json)" == "$rev" && "$(jq -r .version VERSION.json)" == "''${tag#v}" ]]; then
      echo "Rakazo is already at $tag ($rev)."
      exit 0
    fi

    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    mkdir "$work/source"
    tar --exclude=.git --exclude='./result*' -cf - . | tar -C "$work/source" -xf -
    cp VERSION.json "$work/original.json"
    source="$(nix store prefetch-file --json --unpack "https://github.com/elie222/rakazo/archive/$rev.tar.gz")"
    hash="$(jq -er .hash <<< "$source")"
    source_path="$(jq -er .storePath <<< "$source")"
    mapfile -t engines < <(sed -nE "s/^[[:space:]]*'@prisma\/engines-version@[^']+\.([a-f0-9]{40})'.*/\1/p" "$source_path/pnpm-lock.yaml" | sort -u)
    if [[ "''${#engines[@]}" != 1 ]]; then
      echo 'Expected one pinned Prisma engine revision; manual review required' >&2
      exit 1
    fi
    engine="''${engines[0]}"
    engine_x64="$(nix store prefetch-file --json "https://binaries.prisma.sh/all_commits/$engine/debian-openssl-3.0.x/schema-engine.gz" | jq -er .hash)"
    engine_arm64="$(nix store prefetch-file --json "https://binaries.prisma.sh/all_commits/$engine/linux-arm64-openssl-3.0.x/schema-engine.gz" | jq -er .hash)"
    jq --arg version "''${tag#v}" --arg rev "$rev" --arg hash "$hash" --arg sourceDate "$source_date" \
      --arg engine "$engine" --arg x64 "$engine_x64" --arg arm64 "$engine_arm64" \
      '.version = $version | .rev = $rev | .sourceDate = $sourceDate | .hash = $hash |
       .prismaEngineRev = $engine | .prismaEngineHashes = {"x86_64-linux": $x64, "aarch64-linux": $arm64} |
       .pnpmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
      VERSION.json > "$work/source/VERSION.json"

    if nix build "path:$work/source#rakazo.pnpmDeps" --no-link --log-format raw 2> "$work/build.log"; then
      echo 'Dependency hash discovery unexpectedly succeeded with the placeholder hash' >&2
      exit 1
    fi
    mapfile -t hashes < <(sed -nE 's/^[[:space:]]*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+)[[:space:]]*$/\1/p' "$work/build.log")
    if [[ "''${#hashes[@]}" != 1 ]]; then
      cat "$work/build.log" >&2
      echo 'Expected exactly one dependency hash mismatch; checkout left unchanged' >&2
      exit 1
    fi
    jq --arg hash "''${hashes[0]}" '.pnpmDepsHash = $hash' "$work/source/VERSION.json" > "$work/metadata.json"
    mv "$work/metadata.json" "$work/source/VERSION.json"
    nix build "path:$work/source#rakazo.pnpmDeps" --no-link --print-build-logs
    cmp --silent VERSION.json "$work/original.json" || {
      echo 'VERSION.json changed concurrently; refusing to overwrite it' >&2
      exit 1
    }
    next="$(mktemp "$root/.VERSION.json.XXXXXX")"
    cp "$work/source/VERSION.json" "$next"
    chmod 644 "$next"
    mv "$next" VERSION.json
    echo "Updated Rakazo to $tag. Run nix flake check before committing."
  '';
}
