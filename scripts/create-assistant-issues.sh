#!/usr/bin/env bash
# Creates the assistant + voice issues on rouderz/coucou and adds them to the "Coucou fork" board.
# Usage: bash scripts/create-assistant-issues.sh
set -uo pipefail
REPO="rouderz/coucou"
OWNER="rouderz"
PNUM=$(gh project list --owner "$OWNER" --format json --jq '.projects[] | select(.title=="Coucou fork") | .number')

gh label create assistant --repo "$REPO" --color 7057ff --description "Mochi as a coding assistant" --force >/dev/null
gh label create voice     --repo "$REPO" --color d876e3 --description "Voice chat" --force >/dev/null

new_issue() {  # new_issue "<labels>" "<title>"  (body on stdin)
  local url
  url=$(gh issue list --repo "$REPO" --state all --limit 200 --json title,url \
        --jq ".[] | select(.title==\"$2\") | .url" | head -1)
  [ -z "$url" ] && url=$(gh issue create --repo "$REPO" --label "$1" --title "$2" --body-file -) || cat >/dev/null
  [ -n "$PNUM" ] && gh project item-add "$PNUM" --owner "$OWNER" --url "$url" >/dev/null
  echo "  $url  $2"
  sleep 2
}

new_issue "assistant,macos" "[Assistant A] Ask Mochi about the file you're editing" <<'EOF'
Global shortcut (and the existing drag-Mochi-onto-a-window gesture) captures what you're working on and opens the island chat with it attached.

- [ ] Detect the frontmost editor's file through Accessibility (`AXDocument` of the focused window), falling back to the window title + the Claude Code session folder
- [ ] Capture the selected text when the editor exposes it (`AXSelectedText`)
- [ ] Find the project root (nearest `.git`, else the session folder)
- [ ] Chat (Claude Code engine) runs in the project folder with read-only tools: Read, Grep, Glob, WebSearch, WebFetch — never Edit or Bash
- [ ] API-key engine: attach the file (and selection) inline
- [ ] Context chip shows exactly what is attached (`📄 CartService.ts · project`)
- [ ] Settings: shortcut for "Ask about current file"
- [ ] Spike: does `claude -p --ide` give the open file and selection from VS Code/JetBrains?
EOF

new_issue "assistant,macos" "[Assistant B] VS Code / Cursor extension for precise editor context" <<'EOF'
A small extension (works in VS Code, Cursor and Windsurf) that sends Coucou the active file, cursor line, selection and diagnostics over the local socket, so questions like "why is this red?" have exact context.

- [ ] Extension with one command + status bar item, talks to Coucou's socket
- [ ] Payload: file path, language, cursor line, selection, diagnostics for the file
- [ ] Coucou prefers this context over Accessibility when available
- [ ] Packaged as .vsix; JetBrains plugin tracked separately later
EOF

new_issue "assistant,macos" "[Assistant C] Let Mochi propose edits, approved from the island" <<'EOF'
Allow the Edit tool in assistant chats. Every change goes through Claude Code's permission flow, so it shows up in the island as Allow / Deny (with the diff once #19 is done).

- [ ] Opt-in per chat ("Allow edits")
- [ ] Edit requests surface as normal approvals; nothing is written without a click
- [ ] Depends on #19 (diff in approvals)
EOF

new_issue "voice,macos" "[Voice] Push-to-talk: talk to Mochi and hear the answer" <<'EOF'
Hold a shortcut, speak, release: Mochi transcribes, answers through the chat engine and reads the answer aloud.

- [ ] Speech-to-text on-device (SpeechAnalyzer on macOS 26, SFSpeechRecognizer fallback), Spanish and English
- [ ] Mochi "listening" and "speaking" states; live transcript in the island
- [ ] Text-to-speech with system voices (AVSpeechSynthesizer); start speaking at the first sentence to hide latency
- [ ] Settings: shortcut, voice, language, read answers aloud on/off
- [ ] Microphone + speech recognition usage descriptions and entitlements
EOF

new_issue "voice,macos" "[Voice] Optional \"Hey Mochi\" wake word" <<'EOF'
Optional always-listening activation, fully on-device. Depends on push-to-talk.

- [ ] Evaluate: continuous on-device transcription vs a dedicated wake-word model (openWakeWord / Porcupine) — CPU, battery, false positives, licence
- [ ] Off by default; option to only listen while on power
- [ ] Clear indicator while listening; never sends audio before the wake word
EOF

echo "Done."
