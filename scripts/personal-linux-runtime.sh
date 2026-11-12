#!/usr/bin/env bash
set -euo pipefail

source_sha="${1:?source commit required}"
version="${2:?release version required}"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$version" =~ ^0\.1\.[0-9]+$ ]] || {
  printf 'Invalid personal runtime source or version.\n' >&2
  exit 1
}

repo_dir="${GOAT_PERSONAL_LINUX_REPO:-$HOME/goat-build/goat-src}"
cd "$repo_dir"
export PATH="$HOME/goat-build/tools/node-v26.13.0-linux-arm64/bin:$HOME/goat-build/tools/pnpm/bin:$HOME/.cargo/bin:$repo_dir/node_modules/.bin:$PATH"
[[ -z "$(git status --porcelain)" ]] || { printf 'Linux runtime checkout is dirty.\n' >&2; exit 1; }
git fetch origin agent-settings
git checkout agent-settings
git merge --ff-only origin/agent-settings
[[ "$(git rev-parse HEAD)" == "$source_sha" ]] || { printf 'Linux runtime source differs from Mac release.\n' >&2; exit 1; }

archive_dir="$HOME/goat-build/personal-runtime-$version"
archive="$archive_dir/goat-$version-linux-arm64.tar.gz"
if [[ -s "$archive" && -s "$archive.sha256" ]]; then
  (cd "$archive_dir" && sha256sum --check "${archive##*/}.sha256")
  printf '%s\n' "$archive"
  exit 0
fi

restore_manifests() {
  git restore -- apps/server/package.json apps/web/package.json apps/desktop/package.json packages/contracts/package.json
}
trap restore_manifests EXIT
node scripts/update-release-package-versions.ts "$version"
vp run --filter goat build
cargo build --locked --release --manifest-path native/resource-monitor/Cargo.toml
node apps/server/scripts/cli.ts build-exe
mkdir -p "$archive_dir" "$repo_dir/apps/server/dist/resource-monitor/linux-arm64"
cp native/resource-monitor/target/release/goat-resource-monitor apps/server/dist/resource-monitor/linux-arm64/goat-resource-monitor
node scripts/build-cli-archive.ts --platform linux --arch arm64 --version "$version" --output-dir "$archive_dir"
[[ -s "$archive" ]] || { printf 'Linux runtime archive is missing.\n' >&2; exit 1; }
(cd "$archive_dir" && sha256sum "${archive##*/}" > "${archive##*/}.sha256")
(cd "$archive_dir" && sha256sum --check "${archive##*/}.sha256")
printf '%s\n' "$archive"
