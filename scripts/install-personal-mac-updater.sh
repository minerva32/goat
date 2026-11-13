#!/bin/zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
state_dir="$HOME/Library/Application Support/GOAT Personal Updater"
agent_dir="$HOME/Library/LaunchAgents"
agent_file="$agent_dir/io.minerva32.goat.personal-updater.plist"
mkdir -p "$state_dir" "$agent_dir"

if [[ -d /Applications/GOAT.app ]]; then
  identity="$(/usr/bin/codesign -dv --verbose=4 /Applications/GOAT.app 2>&1 | sed -n 's/^Authority=\(Apple Development:.*\)$/\1/p' | head -n 1 || true)"
  [[ -n "$identity" ]] || { print -u2 'Installed GOAT is not Apple Development signed.'; exit 1; }
else
  identity="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/{print $2; exit}')"
fi
[[ -n "$identity" ]] && security find-identity -v -p codesigning | rg -F "$identity" >/dev/null || {
  print -u2 'The installed GOAT signing identity is unavailable in this keychain.'
  exit 1
}

python3 - "$agent_file" "$repo_dir" "$state_dir" "$identity" <<'PY'
import plistlib
import sys

agent_file, repo_dir, state_dir, identity = sys.argv[1:]
with open(agent_file, "wb") as output:
    plistlib.dump(
        {
            "Label": "io.minerva32.goat.personal-updater",
            "ProgramArguments": ["/bin/zsh", f"{repo_dir}/scripts/personal-mac-release.sh"],
            "EnvironmentVariables": {"GOAT_PERSONAL_SIGN_IDENTITY": identity},
            "WorkingDirectory": repo_dir,
            "RunAtLoad": True,
            "StartInterval": 900,
            "LowPriorityIO": True,
            "Nice": 10,
            "StandardOutPath": f"{state_dir}/updater.log",
            "StandardErrorPath": f"{state_dir}/updater.log",
        },
        output,
    )
PY

domain="gui/$(id -u)"
launchctl bootout "$domain" "$agent_file" 2>/dev/null || true
launchctl bootstrap "$domain" "$agent_file"
launchctl print "$domain/io.minerva32.goat.personal-updater" >/dev/null
print -r -- "GOAT personal updater scheduled every 15 minutes: $agent_file"
