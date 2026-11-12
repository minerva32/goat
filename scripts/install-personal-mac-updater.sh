#!/bin/zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
state_dir="$HOME/Library/Application Support/GOAT Personal Updater"
agent_dir="$HOME/Library/LaunchAgents"
agent_file="$agent_dir/io.minerva32.goat.personal-updater.plist"
mkdir -p "$state_dir" "$agent_dir"

python3 - "$agent_file" "$repo_dir" "$state_dir" <<'PY'
import plistlib
import sys

agent_file, repo_dir, state_dir = sys.argv[1:]
with open(agent_file, "wb") as output:
    plistlib.dump(
        {
            "Label": "io.minerva32.goat.personal-updater",
            "ProgramArguments": ["/bin/zsh", f"{repo_dir}/scripts/personal-mac-release.sh"],
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
