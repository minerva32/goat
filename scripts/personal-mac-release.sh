#!/bin/zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
state_dir="${GOAT_PERSONAL_UPDATE_STATE_DIR:-$HOME/Library/Application Support/GOAT Personal Updater}"
mkdir -p "$state_dir"

if [[ "${GOAT_PERSONAL_UPDATE_LOCKED:-0}" != 1 ]]; then
  exec /usr/bin/lockf -k -t 0 "$state_dir/release.lock" /usr/bin/env \
    GOAT_PERSONAL_UPDATE_LOCKED=1 "$0" "$@"
fi

cd "$repo_dir"
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:$repo_dir/node_modules/.bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[[ "$(uname -s)" == Darwin ]] || { print -u2 'Mac release builds require macOS.'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Personal GOAT checkout has uncommitted changes.'; exit 1; }
[[ "$(git branch --show-current)" == personal/agent-settings ]] || {
  print -u2 'Personal GOAT checkout is not on personal/agent-settings.'
  exit 1
}

git fetch fork agent-settings
git merge --ff-only FETCH_HEAD
source_sha="$(git rev-parse HEAD)"
if [[ "${1:-}" != --force && -f "$state_dir/last-source-sha" &&
      "$(cat "$state_dir/last-source-sha")" == "$source_sha" ]]; then
  exit 0
fi

identity="${GOAT_PERSONAL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/{print $2; exit}')}"
[[ -n "$identity" ]] || { print -u2 'No Apple Development signing identity is available.'; exit 1; }
team="$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt RFC2253 | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')"
rg -q '^[A-Z0-9]{10}$' <<< "$team" || { print -u2 'Cannot read the certificate Team ID.'; exit 1; }

pending="$state_dir/pending-release"
if [[ -f "$pending" && "$(head -n 1 "$pending")" == "$source_sha" ]]; then
  version="$(tail -n 1 "$pending")"
else
  latest_patch="$(gh release list --repo minerva32/goat --limit 100 --json tagName --jq '[.[].tagName | select(test("^v0[.]1[.][0-9]+$")) | ltrimstr("v0.1.") | tonumber] | max // 8')"
  version="0.1.$((latest_patch + 1))"
  printf '%s\n%s\n' "$source_sha" "$version" > "$pending"
fi
rg -q '^0[.]1[.][0-9]+$' <<< "$version" || { print -u2 'Invalid pending release version.'; exit 1; }

if [[ "${1:-}" == --dry-run ]]; then
  printf 'Source: %s\nVersion: %s\nTeam: %s\n' "$source_sha" "$version" "$team"
  exit 0
fi

export CSC_NAME="$identity"
export GOAT_CLI_MAC_SIGN_IDENTITY="$identity"
export GOAT_CLI_MAC_SIGN_TEAM="$team"
export GOAT_DESKTOP_UPDATE_FEED_ENABLED=true
export GOAT_DESKTOP_PERSONAL_UPDATE_FEED=true
export GOAT_DESKTOP_UPDATE_REPOSITORY=minerva32/goat

if [[ "${GOAT_PERSONAL_UPDATE_SKIP_CHECK:-0}" != 1 ]]; then
  ./node_modules/.bin/vp run check:changed
fi
output_dir="$state_dir/release-$version"
runtime_dir="$output_dir/ssh-runtime"
mkdir -p "$runtime_dir"
remote_archive="goat-build/personal-runtime-$version/goat-$version-linux-arm64.tar.gz"
ssh -o BatchMode=yes oci-hermes-home "cd ~/goat-build/goat-src && git fetch origin agent-settings && git checkout agent-settings && git merge --ff-only origin/agent-settings && bash scripts/personal-linux-runtime.sh '$source_sha' '$version'"
scp -q "oci-hermes-home:$remote_archive" "$runtime_dir/"
scp -q "oci-hermes-home:$remote_archive.sha256" "$runtime_dir/"
(cd "$runtime_dir" && shasum -a 256 -c "goat-$version-linux-arm64.tar.gz.sha256")
trap 'git restore -- apps/desktop/src/preview/AnnotationStyles.generated.ts' EXIT
node scripts/build-desktop-artifact.ts --platform mac --target zip --arch arm64 \
  --signed --build-version "$version" --output-dir "$output_dir" \
  --ssh-runtime-archive-dir "$runtime_dir"
# The web build regenerates this tracked CSS snapshot from the installed Tailwind dependency.
# The checkout was clean before the build; restore only this generated file afterward.
git restore -- apps/desktop/src/preview/AnnotationStyles.generated.ts
trap - EXIT

zip_file="$output_dir/GOAT-$version-arm64.zip"
manifest="$output_dir/latest-mac.yml"
blockmap="$zip_file.blockmap"
for file in "$zip_file" "$manifest" "$blockmap"; do
  [[ -s "$file" ]] || { print -u2 "Missing release asset: $file"; exit 1; }
done
rg -F "GOAT-$version-arm64.zip" "$manifest" >/dev/null
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Build changed tracked source files.'; exit 1; }

notes="$output_dir/release-notes.md"
printf 'Personal GOAT build for this Mac. Apple Development signed; not notarized.\n\nSource: %s\n' "$source_sha" > "$notes"
tag="v$version"
if gh release view "$tag" --repo minerva32/goat --json body,isDraft > "$output_dir/existing-release.json" 2>/dev/null; then
  jq -r .body "$output_dir/existing-release.json" > "$output_dir/existing-notes.md"
  rg -F "Source: $source_sha" "$output_dir/existing-notes.md" >/dev/null || {
    print -u2 "Release $tag belongs to another source commit."
    exit 1
  }
  if [[ "$(jq -r .isDraft "$output_dir/existing-release.json")" == false ]]; then
    assets="$(gh release view "$tag" --repo minerva32/goat --json assets --jq '[.assets[].name] | join(" ")')"
    for name in "${zip_file:t}" "${manifest:t}" "${blockmap:t}"; do
      [[ " $assets " == *" $name "* ]] || { print -u2 "Published release asset missing: $name"; exit 1; }
    done
    print -r -- "$source_sha" > "$state_dir/last-source-sha.tmp"
    mv "$state_dir/last-source-sha.tmp" "$state_dir/last-source-sha"
    mv "$pending" "$state_dir/last-published-release"
    exit 0
  fi
else
  gh release create "$tag" --repo minerva32/goat --target "$source_sha" \
    --title "GOAT personal $version" --notes-file "$notes" --draft
fi
gh release upload "$tag" "$zip_file" "$manifest" "$blockmap" \
  --repo minerva32/goat --clobber
assets="$(gh release view "$tag" --repo minerva32/goat --json assets --jq '[.assets[].name] | join(" ")')"
for name in "${zip_file:t}" "${manifest:t}" "${blockmap:t}"; do
  [[ " $assets " == *" $name "* ]] || { print -u2 "Release asset missing: $name"; exit 1; }
done
gh release edit "$tag" --repo minerva32/goat --draft=false --latest
print -r -- "$source_sha" > "$state_dir/last-source-sha.tmp"
mv "$state_dir/last-source-sha.tmp" "$state_dir/last-source-sha"
mv "$pending" "$state_dir/last-published-release"
python3 - "$state_dir" "$version" <<'PY'
from pathlib import Path
import shutil
import sys

state = Path(sys.argv[1]).resolve()
current = sys.argv[2]
releases = sorted(
    (path for path in state.glob("release-0.1.*") if path.is_dir()),
    key=lambda path: tuple(int(part) for part in path.name.removeprefix("release-").split(".")),
    reverse=True,
)
for path in releases[2:]:
    if path.name != f"release-{current}" and path.resolve().parent == state:
        shutil.rmtree(path)
PY
print -r -- "Published $tag from $source_sha"
