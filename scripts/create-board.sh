#!/usr/bin/env bash
# Crea el board de GitHub (Project) con todas las tareas del plan del fork de Coucou.
# Requisitos: gh CLI autenticado con permiso de proyectos:
#   brew install gh && gh auth login && gh auth refresh -s project
# Uso:  bash scripts/create-board.sh
# Es idempotente: si una issue con el mismo título ya existe, la reutiliza.
set -uo pipefail
FAILED=()

# Reintenta un comando gh hasta 4 veces con espera creciente (límite secundario de GitHub).
retry() {
  local n=1 out
  while true; do
    if out=$("$@" 2>/tmp/gh-err); then printf "%s" "$out"; return 0; fi
    if [ $n -ge 4 ]; then echo "    ✗ $(cat /tmp/gh-err)" >&2; return 1; fi
    sleep $((n * 15)); n=$((n + 1))
  done
}

OWNER="rouderz"
REPO="rouderz/coucou"
PROJECT_TITLE="Coucou fork"

# ---------------------------------------------------------------- labels
label() { gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force >/dev/null; }
label "fase-0" "c5def5" "Decisiones y montaje del fork"
label "fase-1" "0e8a16" "Modelo configurable y API key"
label "fase-2" "1d76db" "Rendimiento y coste"
label "fase-3" "5319e7" "Arquitectura, tests y CI"
label "fase-4" "fbca04" "Visualización y aprobaciones"
label "fase-5" "d93f0b" "Funciones para nuestro flujo"
label "fase-6" "006b75" "Port a Linux"
label "fase-7" "b60205" "Seguridad, firma y distribución"
label "fase-8" "e99695" "Multi-proveedor (OpenAI, Codex…)"
label "macos"   "000000" "App macOS (Swift)"
label "windows" "0078d4" "App Windows (Tauri)"
label "linux"   "f9d0c4" "Linux"
echo "✓ labels"

# ---------------------------------------------------------------- project
PNUM=$(gh project list --owner "$OWNER" --format json --jq ".projects[] | select(.title==\"$PROJECT_TITLE\") | .number" | head -1)
if [ -z "$PNUM" ]; then
  PNUM=$(gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json --jq .number)
  gh project link "$PNUM" --owner "$OWNER" --repo "$REPO" >/dev/null || true
fi
PID=$(gh project view "$PNUM" --owner "$OWNER" --format json --jq .id)

FID=$(gh project field-list "$PNUM" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Fase") | .id')
if [ -z "$FID" ]; then
  gh project field-create "$PNUM" --owner "$OWNER" --name "Fase" --data-type SINGLE_SELECT \
    --single-select-options "F0,F1,F2,F3,F4,F5,F6,F7,F8" >/dev/null
  FID=$(gh project field-list "$PNUM" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Fase") | .id')
fi
echo "✓ project #$PNUM"

OPTS=$(gh project field-list "$PNUM" --owner "$OWNER" --format json \
  --jq '.fields[] | select(.name=="Fase") | .options[] | "\(.name)=\(.id)"')
opt_id() { printf "%s\n" "$OPTS" | sed -n "s/^$1=//p"; }

# ---------------------------------------------------------------- issues
# issue "<fase F0..F8>" "<labels coma>" "<título>"  (cuerpo por stdin)
issue() {
  local fase="$1" labels="$2" title="$3" body url item oid
  body=$(cat)
  url=$(retry gh issue list --repo "$REPO" --state all --limit 200 --json title,url \
        --jq ".[] | select(.title==\"$title\") | .url" | head -1)
  if [ -z "$url" ]; then
    url=$(retry gh issue create --repo "$REPO" --title "$title" --body "$body" --label "$labels") \
      || { FAILED+=("crear: $title"); return; }
    sleep 3
  fi
  item=$(retry gh project item-add "$PNUM" --owner "$OWNER" --url "$url" --format json --jq .id) \
    || { FAILED+=("añadir al board: $title"); return; }
  oid=$(opt_id "$fase")
  retry gh project item-edit --id "$item" --project-id "$PID" --field-id "$FID" \
    --single-select-option-id "$oid" >/dev/null || FAILED+=("campo Fase: $title")
  echo "  ✓ $fase  $title"
  sleep 2
}

# ---- Fase 0
issue F0 "fase-0,macos" "[F0] Línea base: compilar y medir CPU, RAM y tokens" <<'EOF'
Compilar la app de macOS tal cual (`cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy build`).
Medir y anotar aquí: CPU con la isla oculta, CPU con la isla abierta, RAM, y tokens del 1.er y 10.º mensaje de un chat con un PDF adjunto.
Estas cifras son la referencia para la Fase 2.
EOF

# ---- Fase 1
issue F1 "fase-1,macos" "[F1] macOS: modelo configurable en Ajustes (Opus 5.5 por defecto)" <<'EOF'
- Sustituir `private let model = "claude-sonnet-4-6"` en `ClaudeService.swift` por un ajuste persistido en `UserDefaults` (patrón de `AppState`).
- Selector en `SettingsView.swift` (GroupBox "Anthropic API"): `claude-opus-5-5` (defecto), `claude-sonnet-5-5`, `claude-haiku-4-5`, `claude-fable-5-1`.
- Campo "modelo personalizado" para cualquier ID futuro.
EOF
issue F1 "fase-1,windows" "[F1] Windows: actualizar lista de modelos y defecto a claude-opus-5-5" <<'EOF'
- `windows/src/settings/main.ts` → `MODELS` con los modelos actuales.
- `windows/src-tauri/src/claude.rs` → `DEFAULT_MODEL = "claude-opus-5-5"`.
EOF
issue F1 "fase-1,macos,windows" "[F1] max_tokens configurable y error claro si la clave no tiene acceso al modelo" <<'EOF'
- Hoy: 4096 en el chat y 1024 en la búsqueda (macOS), `MAX_TOKENS = 4096` (Windows).
- Mostrar un mensaje entendible en la isla cuando la API devuelva 403/404 por modelo no disponible (p. ej. Fable).
EOF

issue F1 "fase-1,macos,windows" "[F1] Chat con la suscripción de Claude Code (sin API key)" <<'EOF'
Usar el `claude` oficial instalado como motor del chat de Mochi, en modo no interactivo, para consumir del plan Pro/Max en lugar de pagar la API aparte.

- [ ] Ejecutar `claude -p "<pregunta>" --output-format stream-json --verbose --include-partial-messages` y mostrar el texto mientras llega
- [ ] Conversación multi-turno con `--resume <session_id>`
- [ ] Modelo elegido en Ajustes vía `--model`
- [ ] Seguridad: carpeta temporal como directorio de trabajo, solo `WebSearch`/`WebFetch` permitidos, `--permission-mode dontAsk`; el chat nunca toca archivos del usuario
- [ ] Marcar estas sesiones con una variable de entorno (p. ej. `COUCOU_INTERNAL=1`) para que el hook de Coucou las ignore y Mochi no las muestre como trabajo
- [ ] Adjuntos: pasar la ruta del archivo copiado a la carpeta temporal
- [ ] Ajustes: "Motor del chat" → Suscripción de Claude Code (defecto) / API key; detectar si `claude` está instalado y con sesión iniciada
- [ ] Nunca leer ni reutilizar el token de sesión de Claude: solo el binario oficial sin modificar (condiciones de Anthropic)
- Encaja como adaptador "Claude Code" del puerto `ChatProvider` (#16)

Docs: https://code.claude.com/docs/en/headless · https://code.claude.com/docs/en/legal-and-compliance
EOF
issue F1 "fase-1,macos,windows" "[F1] Barra de uso del plan: límite de 5 horas, semanal y contexto" <<'EOF'
Mostrar en la isla cuánto queda del plan y cuándo se reinicia, como el panel de uso de Claude.

**Fuente oficial de datos:** el JSON que Claude Code envía a su statusline incluye `rate_limits.five_hour` y `rate_limits.seven_day` (`used_percentage`, `resets_at` en epoch) y `context_window` (`used_percentage`, `context_window_size`). Solo existe para suscriptores Pro/Max y tras la primera respuesta de la sesión.

- [ ] Script de statusline de Coucou que reenvía el JSON al socket de la app; si el usuario ya tiene una statusline, encadenarla y devolver su salida tal cual
- [ ] Instalarlo en `~/.claude/settings.json` con la misma regla que los hooks: copia fechada, merge, mostrar el diff y escribir solo tras confirmar
- [ ] Vista en la isla: barra "Límite de 5 h" con % y "se reinicia en X h Y min", barra "Semanal" con % y día/hora de reinicio, barra de contexto de la sesión activa (tokens / total)
- [ ] Colores por umbral (normal, >75 %, >90 %) y aviso al acercarse al límite
- [ ] Indicar "actualizado hace X min" (los datos solo llegan mientras hay una sesión activa) y ocultar cada barra si su ventana no está presente
- [ ] Versión compacta en la pastilla de Claude Code

Docs: https://code.claude.com/docs/en/statusline
EOF

# ---- Fase 2
issue F2 "fase-2,macos" "[F2] macOS: pausar mini-Mochis cuando la isla está oculta" <<'EOF'
`BotCanvasView.swift:137` usa `TimelineView(.animation)` sin `paused:`. Pausarlo cuando la isla está oculta o el mini-Mochi está quieto (como ya hace el Mochi principal en la línea 13).
Regla del proyecto: 0 % CPU con la isla oculta.
EOF
issue F2 "fase-2,macos" "[F2] macOS: quitar el timer de 0,1 s de la barra de progreso" <<'EOF'
`IslandRootView.swift:390` usa `Timer.scheduledTimer(withTimeInterval: 0.1…)`. Mover el cálculo al `TimelineView` existente.
EOF
issue F2 "fase-2,macos,windows" "[F2] Pollers: intervalo adaptativo y backoff ante errores y 429" <<'EOF'
Hoy: n8n 15 s, Stripe/Vercel 30 s, Resend 60 s, GitHub/Cal.com/Notion 300 s, siempre.
- Intervalo más largo con la isla oculta o el Mac dormido.
- Backoff exponencial ante errores y respetar `Retry-After`.
EOF
issue F2 "fase-2,macos,windows" "[F2] GitHub poller: ETag / If-None-Match" <<'EOF'
Las respuestas 304 no cuentan contra el rate limit. Guardar el `ETag` por endpoint y reenviarlo.
EOF
issue F2 "fase-2,macos,windows" "[F2] Chat: límite de historial y prompt caching de adjuntos" <<'EOF'
`conversationMessages` crece sin límite y reenvía el adjunto en base64 en cada turno.
- Recortar o resumir turnos antiguos.
- `cache_control` en el bloque del adjunto y en el system prompt.
EOF
issue F2 "fase-2,macos,windows" "[F2] Chat: respuestas en streaming" <<'EOF'
`stream: true` y mostrar el texto a medida que llega (hoy espera hasta 45–90 s y lo muestra de golpe).
EOF

# ---- Fase 3
issue F3 "fase-3,macos,windows" "[F3] Tests del hook: eventos y respuestas allow/deny/always" <<'EOF'
Cubrir `nb-hook` (Python, embebido en `HookServer.swift`) y `windows/hook/src/main.rs`: parseo de eventos, respuesta para cada decisión y salida inmediata si la app no responde.
EOF
issue F3 "fase-3,macos,windows" "[F3] Tests de pollers con respuestas grabadas" <<'EOF'
Fixtures JSON por integración; verificar parseo y manejo de errores.
EOF
issue F3 "fase-3,macos,windows" "[F3] CI: compilar y testear en cada PR" <<'EOF'
GitHub Actions: build + tests de macOS y Windows en cada PR; `main` protegida.
EOF
issue F3 "fase-3,macos" "[F3] Partir IslandViewContent.swift en vistas por estado" <<'EOF'
≈2 800 líneas. Una vista por estado: aprobación, chat, subida, integraciones, resultado.
EOF
issue F3 "fase-3,macos" "[F3] Partir BotEngine.swift" <<'EOF'
≈1 500 líneas. Separar dibujo, animación y emociones.
EOF
issue F3 "fase-3,macos,windows" "[F3] Arquitectura: puerto ChatProvider + adaptador Anthropic" <<'EOF'
Protocolo Swift / trait Rust con `stream(req)` y `capabilities()`. `ChatRequest` propio del núcleo; el adaptador Anthropic traduce. Las vistas dejan de llamar a `URLSession` directamente.
EOF
issue F3 "fase-3,macos,windows" "[F3] Arquitectura: puertos AgentSource, IntegrationSource, SecretStore y Transport" <<'EOF'
Interfaces solo donde hay variación real. Adaptadores actuales: Claude Code, 7 integraciones, Keychain/Credential Manager, socket/pipe.
EOF
issue F3 "fase-3" "[F3] Spike: núcleo Rust compartido con UniFFI" <<'EOF'
Evaluar si macOS puede enlazar un núcleo Rust común (sesiones, aprobaciones, chat, reglas) y dejar SwiftUI solo para la ventana del notch. Entregable: prueba mínima y decisión.
EOF

# ---- Fase 4
issue F4 "fase-4,macos,windows" "[F4] Aprobaciones: diff de ediciones y comando resaltado" <<'EOF'
Mostrar el diff en Edit/Write y el comando bash con resaltado de sintaxis.
EOF
issue F4 "fase-4,macos,windows" "[F4] Indicador de riesgo por colores en aprobaciones" <<'EOF'
Rojo: `rm -rf`, `git push --force`, `curl | sh`… Ámbar: escrituras e instalaciones. Verde: lecturas.
EOF
issue F4 "fase-4,macos,windows" "[F4] Always pide confirmación y muestra la regla exacta" <<'EOF'
Antes de persistir `updatedPermissions`, mostrar qué regla quedará guardada para siempre.
EOF
issue F4 "fase-4,macos,windows" "[F4] Línea de tiempo de la sesión" <<'EOF'
Archivos leídos, editados y comandos ejecutados, con duración.
EOF
issue F4 "fase-4,macos,windows" "[F4] Medidor de contexto y tokens por sesión" <<'EOF'
Leer el transcript que Claude Code referencia en los eventos de hook.
EOF
issue F4 "fase-4,macos,windows" "[F4] Varias sesiones simultáneas" <<'EOF'
Una pestaña o un Mochi por sesión, cada uno con su estado.
EOF
issue F4 "fase-4,macos,windows" "[F4] Pastillas con datos: sparkline de Stripe y tiempo de build de Vercel" <<'EOF'
Que las pastillas de integración muestren una cifra o tendencia, no solo el estado.
EOF

# ---- Fase 5
issue F5 "fase-5,macos,windows" "[F5] Integración con Linear" <<'EOF'
Issue en curso, asignaciones nuevas y cambios de estado, con su Mochi de color. Clave en el Llavero.
EOF
issue F5 "fase-5,macos,windows" "[F5] Vincular sesión de Claude Code con su issue de Linear" <<'EOF'
Por nombre de rama (p. ej. `sho-475`) o por directorio del proyecto.
EOF
issue F5 "fase-5,macos,windows" "[F5] Atajos globales para Allow / Deny" <<'EOF'
Aprobar o denegar sin ratón (p. ej. ⌥⏎ / ⌥⌫). Nunca aprobar sin una acción explícita del usuario.
EOF
issue F5 "fase-5,macos,windows" "[F5] Reglas de auto-aprobación por proyecto" <<'EOF'
Ej.: `Read` y `Grep` siempre en ciertos proyectos. Con registro visible de lo aprobado.
EOF
issue F5 "fase-5,macos" "[F5] Modo No molestar" <<'EOF'
Ligado al Focus de macOS o a reuniones del calendario.
EOF
issue F5 "fase-5,macos,windows" "[F5] Aviso al móvil por aprobaciones pendientes" <<'EOF'
Cuando una aprobación lleve más de X segundos esperando.
EOF
issue F5 "fase-5,macos" "[F5] Vista previa antes de enviar correo" <<'EOF'
Hoy el AppleScript crea el mensaje con `visible:false` y lo envía. Mostrar destinatario, asunto y cuerpo y pedir confirmación.
EOF

# ---- Fase 6
issue F6 "fase-6,linux" "[F6] Linux: Unix socket para hook → app" <<'EOF'
Sustituir el named pipe por un socket en `$XDG_RUNTIME_DIR`, verificado con `SO_PEERCRED`. Hook y app.
EOF
issue F6 "fase-6,linux" "[F6] Linux: abstracciones de plataforma" <<'EOF'
UID en lugar de SID, `chrono` en lugar de `GetLocalTime`, `xdg-open`, Secret Service en `keyring`. Todo tras `#[cfg(target_os)]`.
EOF
issue F6 "fase-6,linux" "[F6] Linux: isla en X11" <<'EOF'
Posición del cursor con XQueryPointer, click-through con XShape o `set_ignore_cursor_events`. GNOME vía XWayland.
EOF
issue F6 "fase-6,linux" "[F6] Linux: isla en Wayland con layer-shell" <<'EOF'
`gtk-layer-shell` para KDE, Sway y Hyprland. "Peek" por atajo en vez de hover.
EOF
issue F6 "fase-6,linux" "[F6] Linux: paquetes .deb/.rpm/AppImage y job de CI" <<'EOF'
Bundles de Tauri y workflow en GitHub Actions.
EOF

# ---- Fase 7
issue F7 "fase-7,macos" "[F7] macOS: firma Developer ID y notarización" <<'EOF'
Requiere cuenta de Apple Developer. Mantener el bundle id `fr.louisraille.NotchBuddy` (Llavero y permisos dependen de él).
EOF
issue F7 "fase-7,windows" "[F7] Windows: firma Authenticode" <<'EOF'
Para evitar el aviso de SmartScreen.
EOF
issue F7 "fase-7,macos,windows" "[F7] Actualizaciones automáticas firmadas" <<'EOF'
Updater de Tauri (Windows/Linux) y Sparkle (macOS), con builds solo desde CI.
EOF
issue F7 "fase-7" "[F7] README y LICENSE del fork" <<'EOF'
Nombre y descripción propios, manteniendo el aviso MIT del autor original.
EOF

# ---- Fase 8
issue F8 "fase-8,macos,windows" "[F8] Adaptadores de chat: OpenAI, Gemini, OpenRouter y Ollama" <<'EOF'
Implementan el puerto `ChatProvider` de la Fase 3. Declarar capacidades (PDF, imágenes, búsqueda web) por proveedor.
EOF
issue F8 "fase-8,macos,windows" "[F8] Ajustes: selector de proveedor y clave por proveedor" <<'EOF'
Proveedor + modelo + clave (en Llavero / Credential Manager).
EOF
issue F8 "fase-8,macos,windows" "[F8] Codex CLI: relay de hooks y sesiones en la isla" <<'EOF'
Hooks en `~/.codex/hooks.json` (PreToolUse, PermissionRequest, Stop…). Contrato binario allow/deny: "Always" con reglas propias. El usuario debe marcar el hook como confiable en Codex.
EOF

# ---- Idiomas
issue F5 "fase-5,macos,windows" "[F5] Idiomas: interfaz en español e inglés" <<'EOF'
Hoy los textos de la app están fijos en inglés, los avisos de permisos de `project.yml` en francés y la búsqueda estructurada obliga a responder en inglés.

- [ ] macOS: String Catalog (`Localizable.xcstrings`) incluido en `project.yml`; los `Text("…")` de SwiftUI se traducen solos, los textos fuera de vistas (errores de `ClaudeService`, `statusMessage`) con `String(localized:)`
- [ ] macOS: traducir `NSAppleEventsUsageDescription` y `NSAccessibilityUsageDescription` (`InfoPlist.xcstrings`)
- [ ] Windows: diccionario de textos en el frontend TypeScript y en los menús de la bandeja
- [ ] Seguir el idioma del sistema, con opción de forzarlo en Ajustes
- [ ] Prompt de búsqueda: responder en el idioma del usuario en lugar de "Reply in English"
- [ ] Idiomas iniciales: español e inglés (francés opcional, ya que el original es francés)
EOF

# ---- Rebranding (requisito antes de distribuir)
issue F7 "fase-7,macos,windows" "[F7] Rebranding: nombre, icono, personaje y sonidos propios" <<'EOF'
`LICENSE-ASSETS.md` reserva al autor original el nombre "Coucou" y "Mochi", el personaje Mochi (diseño, expresiones y animaciones), los iconos, los 28 sonidos y el material de `docs/media/` y `design/`. El código es MIT, pero **no podemos distribuir** la app (releases, instalarla a otras personas) con esos elementos.

**Bloquea cualquier distribución.**

- [ ] Nombre nuevo para la app y para el personaje
- [ ] Rediseñar el personaje: Mochi está dibujado en código (`BotEngine.swift`, `windows/src/mochi/engine.ts`); hay que cambiar su diseño, no solo el nombre
- [ ] Icono de app y de barra de menús nuevos (`NotchBuddy/Assets.xcassets/`, `windows/src-tauri/icons/`)
- [ ] Sonidos propios (`NotchBuddy/Resources/sounds/`)
- [ ] Sustituir o quitar capturas y GIFs (`docs/media/`, `design/`, `windows/screenshots/`)
- [ ] Nuevo bundle id (hoy `fr.louisraille.NotchBuddy`) y migración de claves del Llavero
- [ ] Quitar referencias al autor en el system prompt ("Louis's personal AI assistant") y en textos de la app
- [ ] `LICENSE`: mantener el aviso MIT original y añadir el nuestro para las modificaciones
- [ ] Alternativa: pedir permiso escrito al autor si queremos conservar algo
EOF

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "✓ listo: https://github.com/users/$OWNER/projects/$PNUM"
else
  echo "⚠ Terminó con ${#FAILED[@]} fallos (vuelve a ejecutar el script para reintentarlos):"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
