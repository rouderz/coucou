#!/usr/bin/env bash
# Organizes rouderz/coucou's open issues into three iterations (milestones):
#   1 · Now   — small, high value, polishes what already works
#   2 · Next  — bigger features on top of the current base
#   3 · Later — new platforms, providers, distribution, nice-to-have
# Safe to re-run: milestones and issues are matched by title, nothing is duplicated.
# Usage: bash scripts/roadmap.sh
set -uo pipefail
REPO="rouderz/coucou"
OWNER="rouderz"
NOW="1 · Now"; NEXT="2 · Next"; LATER="3 · Later"

milestone() {  # milestone "<title>" "<description>"
  gh api "repos/$REPO/milestones?state=all&per_page=100" --jq ".[] | select(.title==\"$1\") | .number" | grep -q . \
    || gh api "repos/$REPO/milestones" -f title="$1" -f description="$2" >/dev/null
}
milestone "$NOW"   "Small, high-value polish of what already works. One PR per issue."
milestone "$NEXT"  "Bigger features built on the current base."
milestone "$LATER" "Other platforms, providers, distribution and nice-to-haves."

OPEN=$(gh issue list --repo "$REPO" --state open --limit 300 --json number,title)
PNUM=$(gh project list --owner "$OWNER" --format json --jq '.projects[] | select(.title=="Coucou fork") | .number')

plan() {  # plan "<milestone>" "<distinctive part of the title>"  (every open issue that matches)
  local nums
  nums=$(echo "$OPEN" | jq -r --arg k "$2" '.[] | select(.title | ascii_downcase | contains($k | ascii_downcase)) | .number')
  if [ -z "$nums" ]; then echo "  –  not open (done or renamed): $2"; return; fi
  for n in $nums; do
    gh issue edit "$n" --repo "$REPO" --milestone "$1" >/dev/null && echo "  #$n → $1  ($2)"
  done
}

new_issue() {  # new_issue "<milestone>" "<labels>" "<title>"  (body on stdin)
  local url
  url=$(gh issue list --repo "$REPO" --state all --limit 300 --json title,url \
        --jq ".[] | select(.title==\"$3\") | .url" | head -1)
  if [ -z "$url" ]; then
    url=$(gh issue create --repo "$REPO" --label "$2" --milestone "$1" --title "$3" --body-file -)
    [ -n "$PNUM" ] && gh project item-add "$PNUM" --owner "$OWNER" --url "$url" >/dev/null
    echo "  + $url  $3"
    sleep 2
  else
    cat >/dev/null
    gh issue edit "$url" --repo "$REPO" --milestone "$1" >/dev/null
  fi
}

echo "New issues"
new_issue "$NOW" "macos" "[Perf] Open island uses ~35% CPU: profile and fix" <<'B'
Idle is fine (~0.2%), but with the island open CPU sits around 35%.

- [ ] Record with Instruments (Time Profiler + SwiftUI) while the island is open on each view
- [ ] Find the views that re-render every frame (TimelineView, animations, @Published churn)
- [ ] Target: under 10% with the island open and nothing animating
B
new_issue "$NEXT" "macos" "[Chat] Search chat history and rename chats" <<'B'
- [ ] Search box at the top of the history list (title + message text)
- [ ] Rename a chat (double-click the title)
- [ ] Pin chats to keep them past the 50-chat limit
B
new_issue "$NEXT" "voice,macos" "[Voice] Voice polish: pick the voice, speed, and interrupt by talking" <<'B'
- [ ] Settings: choose the system voice and speaking rate
- [ ] Holding the shortcut while Mochi talks stops it and listens (already stops; check it feels instant)
- [ ] Suggest downloading an Enhanced/Premium voice when only compact ones are installed
B

echo
echo "1 · Now"
plan "$NOW" "CI:"
plan "$NOW" "README y LICENSE"
plan "$NOW" "Idiomas"
plan "$NOW" "Medidor de contexto"

echo
echo "2 · Next"
plan "$NEXT" "Varias sesiones simultáneas"
plan "$NEXT" "Atajos globales para Allow"
plan "$NEXT" "Indicador de riesgo"
plan "$NEXT" "Always pide confirmación"
plan "$NEXT" "Partir IslandViewContent"
plan "$NEXT" "Línea de tiempo de la sesión"
plan "$NEXT" "Modo No molestar"
plan "$NEXT" "Tests del hook"
plan "$NEXT" "[Assistant B]"

echo
echo "3 · Later"
for k in "Hey Mochi" "Integración con Linear" "Vincular sesión" "Reglas de auto-aprobación" \
         "Aviso al móvil" "Vista previa antes de enviar" "Pastillas con datos" "Partir BotEngine" \
         "Tests de pollers" "puerto ChatProvider" "AgentSource" "núcleo Rust" "Adaptadores de chat" \
         "selector de proveedor" "Codex CLI" "Linux:" "firma Developer ID" "Authenticode" \
         "Actualizaciones automáticas" "Rebranding" "Windows:" "ETag" "backoff"; do
  plan "$LATER" "$k"
done

echo
echo "Open issues without a milestone (review: done already, or pick an iteration):"
gh issue list --repo "$REPO" --state open --limit 300 --search "no:milestone" --json number,title \
  --jq '.[] | "  #\(.number)  \(.title)"'

echo
echo "Roadmap: https://github.com/$REPO/milestones"
