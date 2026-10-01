#!/usr/bin/env bash
# Plays a fake Claude Code turn (read, edit, done) through Coucou's hook, to try the
# live view without a real session. Open the island on the Claude Code card first.
#   bash scripts/simulate-claude-edit.sh          # full turn
#   bash scripts/simulate-claude-edit.sh --approve  # the edit asks for permission
set -euo pipefail
H="$HOME/Library/Application Support/NotchBuddy/nb-hook"
F=/tmp/invoice.ts
printf 'import { Item } from "./types"\n\nconst TVA = 0.196\n\nexport function total(items: Item[]) {\n  const sum = items.reduce((s, i) => s + i.price, 0)\n  return sum * (1 + TVA)\n}\n' > "$F"
base='"cwd":"/tmp","session_id":"demo","term_program":"vscode"'
ev() { echo "{$1,$base}" | "$H" > /dev/null; sleep "${2:-1}"; }

ev '"hook_event_name":"UserPromptSubmit","prompt":"Update VAT to 20%"'
ev '"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'$F'"},"tool_use_id":"t1"'
ev '"hook_event_name":"PostToolUse","tool_name":"Read","tool_use_id":"t1"'
edit='"tool_name":"Edit","tool_input":{"file_path":"'$F'","old_string":"const TVA = 0.196","new_string":"const TVA = 0.20"}'
if [ "${1:-}" = "--approve" ]; then
  echo "Waiting for Allow / Deny in the island…"
  ev '"hook_event_name":"PermissionRequest",'"$edit" 0
fi
ev '"hook_event_name":"PreToolUse",'"$edit"',"tool_use_id":"t2"' 2
ev '"hook_event_name":"PostToolUse","tool_name":"Edit","tool_use_id":"t2"'
ev '"hook_event_name":"Stop"' 0
echo "Done."
