// Spanish (#48 on macOS) — the interface in English or Spanish, following the
// system or the choice in Settings.
//
// The texts are translated where they're shown: a watcher over the page swaps
// any text (or title / placeholder) that is exactly a known English string,
// fills patterns for the ones with numbers or names in them, and translates
// "A · B" piece by piece. What the user or the tools wrote — chat messages,
// commands, file names, diffs — is left alone.

export type Lang = "en" | "es";

let lang: Lang = "en";

export function resolveLanguage(pref: string | undefined, system = typeof navigator !== "undefined" ? navigator.language : "en"): Lang {
  if (pref === "en" || pref === "es") return pref;
  return system.toLowerCase().startsWith("es") ? "es" : "en";
}

export function setLanguage(pref: string | undefined) {
  lang = resolveLanguage(pref);
  if (typeof document !== "undefined") document.documentElement.lang = lang;
}

export function language(): Lang {
  return lang;
}

const ES: Record<string, string> = {
  // header, tabs, common
  "Overview": "Resumen", "Ask": "Preguntar", "Drop": "Soltar", "Settings": "Ajustes", "Mute": "Silenciar",
  "Settings…": "Ajustes…", "Back": "Atrás", "Cancel": "Cancelar", "Save": "Guardar", "Remove": "Quitar",
  "Delete": "Borrar", "Dismiss": "Descartar", "Dismiss all": "Descartar todo", "Open": "Abrir", "Refresh": "Actualizar",
  "Retry": "Reintentar", "OK": "OK", "Details": "Detalles", "Download": "Descargar", "Send": "Enviar", "Done": "Hecho",
  "Allow": "Permitir", "Deny": "Denegar", "Always": "Siempre", "Inbox": "Bandeja", "Timeline": "Cronología",
  "History": "Historial", "New chat": "Nuevo chat", "Chats": "Chats", "Chat": "Chat", "General": "General",
  "Integrations": "Integraciones", "Integration": "Integración", "Updates": "Actualizaciones", "Sound": "Sonido",
  "Auto-close": "Cierre automático", "Off": "Desactivado", "Until 9:00": "Hasta las 9:00", "On": "Activado",
  "Do not disturb": "No molestar", "Open terminal": "Abrir terminal", "Open Visual Studio Code": "Abrir Visual Studio Code",
  "Open n8n": "Abrir n8n", "Open in n8n": "Abrir en n8n", "Copied ✓": "Copiado ✓", "Copy as Markdown": "Copiar como Markdown",
  "What this session did": "Lo que hizo esta sesión", "Checking…": "Comprobando…", "Posting…": "Publicando…",
  "Session": "Sesión", "No session yet": "Aún no hay sesión", "Nothing recorded yet.": "Aún no hay nada registrado.",
  "seconds after you leave the island": "segundos después de salir de la isla",

  // views
  "Ask me anything…": "Pregúntame lo que quieras…", "Continue…": "Continúa…", "Ask a question": "Haz una pregunta",
  "Ask Claude": "Preguntar a Claude", "Drop your files here": "Suelta tus archivos aquí",
  "Drop a file or window, or ask me anything.": "Suelta un archivo o una ventana, o pregúntame lo que quieras.",
  "What do you want to do with it?": "¿Qué quieres hacer con él?",
  "Nothing running right now.": "No hay nada en marcha ahora.",
  "Give me a sec — back to work in three seconds.": "Un segundo — vuelvo al trabajo en tres segundos.",
  "Too many hits at once.": "Demasiados golpes a la vez.", "Workflow stopped.": "El workflow se detuvo.",
  "Answer in your terminal — Coucou can't reply for you yet.": "Responde en tu terminal — Coucou aún no puede responder por ti.",
  "Claude Code finished": "Claude Code terminó", "Claude Code is asking a question": "Claude Code tiene una pregunta",
  "Claude needs an answer.": "Claude necesita una respuesta.", "Claude is searching…": "Claude está buscando…",
  "Completed successfully.": "Completado con éxito.", "Session finished": "Sesión terminada",
  "Session stopped on an error.": "La sesión se detuvo por un error.", "No detail available.": "No hay detalles.",
  "No error details available.": "No hay detalles del error.", "Sending by email isn't in this version.": "Enviar por correo no está en esta versión.",
  "Result": "Resultado", "needs permission": "necesita permiso", "· Codex needs permission": "· Codex necesita permiso",
  "No saved chats yet.": "Aún no hay chats guardados.", "All caught up": "Todo al día",
  "Nothing needs you on GitHub or Linear.": "Nada te espera en GitHub ni en Linear.",
  "Review requested": "Revisión solicitada", "Mentioned you": "Te mencionó", "Assignment": "Asignación",
  "New comment": "Nuevo comentario", "Update": "Novedad",

  // approvals and risk
  "Low risk": "Riesgo bajo", "Medium risk": "Riesgo medio", "High risk": "Riesgo alto",
  "Always ask": "Preguntar siempre", "Low + medium": "Bajo + medio", "Ask every time": "Preguntar cada vez",
  "Answered at once and logged in the timeline. High risk always asks.": "Se responde al momento y queda en la cronología. El riesgo alto siempre pregunta.",
  "read only": "solo lectura", "external tool": "herramienta externa", "unknown tool": "herramienta desconocida",
  "sensitive file": "archivo sensible", "outside the project": "fuera del proyecto", "outside your home folder": "fuera de tu carpeta personal",
  "changes a file": "cambia un archivo", "deletes files recursively": "borra archivos de forma recursiva",
  "runs as administrator": "se ejecuta como administrador", "force-pushes": "hace push forzado",
  "discards changes": "descarta cambios", "deletes untracked files": "borra archivos sin seguimiento",
  "discards work": "descarta trabajo", "runs a downloaded script": "ejecuta un script descargado",
  "opens permissions to everyone": "abre permisos a todos", "writes a disk": "escribe en un disco",
  "deletes data": "borra datos", "changes infrastructure": "cambia infraestructura", "publishes": "publica",
  "kills processes": "mata procesos", "deletes files": "borra archivos", "installs packages": "instala paquetes",
  "changes the repository": "cambia el repositorio", "changes files": "cambia archivos", "writes a file": "escribe un archivo",
  "uses the network": "usa la red", "talks to a service": "habla con un servicio", "edits files": "edita archivos",
  "reads the repository": "lee el repositorio", "builds or tests": "compila o prueba", "runs a command": "ejecuta un comando",
  "new file": "archivo nuevo", "deletes the file": "borra el archivo",

  // steps
  "Run": "Ejecuta", "Read": "Lee", "Write": "Escribe", "Edit": "Edita", "Find": "Busca", "Search": "Busca",
  "Web search": "Búsqueda web", "Fetch": "Descarga", "Plan": "Plan", "Agent": "Agente", "List": "Lista",
  "⚠ failed": "⚠ falló", "+ subagent": "+ subagente", "• subagent done": "• subagente terminado",
  "Session started": "Sesión iniciada", "Session ended": "Sesión terminada", "The turn failed": "El turno falló",

  // integrations
  "Hooks not installed": "Hooks sin instalar", "Key not configured": "Clave sin configurar",
  "Connected · loading…": "Conectado · cargando…", "Deployments": "Despliegues", "Deployment": "Despliegue",
  "Ready": "Listo", "Canceled": "Cancelado", "Error": "Error", "Emails": "Correos", "Repositories": "Repositorios",
  "Total stars": "Estrellas", "Payments": "Pagos", "Payment": "Pago", "Recent": "Recientes", "Untitled": "Sin título",
  "Schedule": "Agenda", "No calls scheduled": "No hay llamadas programadas", "Meeting": "Reunión",
  "Workflow": "Workflow", "Success": "Éxito", "Failed": "Falló", "Assigned to you": "Asignado a ti",
  "Nothing open is assigned to you.": "No tienes nada abierto asignado.", "● session": "● sesión",

  // settings window
  "Claude Code": "Claude Code", "Install hooks…": "Instalar hooks…", "Reinstall hooks…": "Reinstalar hooks…",
  "Update hooks…": "Actualizar hooks…", "Uninstall hooks…": "Desinstalar hooks…", "Uninstall": "Desinstalar",
  "Relay": "Relé", "The relay isn't installed yet.": "El relé aún no está instalado.",
  "Coucou is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there.":
    "Coucou está conectado a tus sesiones de Claude Code. Las herramientas, preguntas y permisos aparecen en la isla y puedes responderlos ahí.",
  "Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing.":
    "Instala los hooks para ver tus sesiones de Claude Code en la isla y aprobar permisos sin dejar lo que estás haciendo.",
  "Coucou's hooks are installed but out of date. Update them to get every event and approvals that don't time out.":
    "Los hooks de Coucou están instalados pero desactualizados. Actualízalos para recibir todos los eventos y aprobaciones que no caducan.",
  "The plan usage bars come from Claude Code's status line: the hooks add Coucou's, unless you already have your own (then it stays, and the bars stay empty).":
    "Las barras de uso del plan vienen de la línea de estado de Claude Code: los hooks añaden la de Coucou, salvo que ya tengas la tuya (entonces se queda, y las barras quedan vacías).",
  "The relay (coucou-hook) is not in place yet. Restart Coucou; if it still fails, build it with `cargo build -p coucou-hook`.":
    "El relé (coucou-hook) aún no está en su sitio. Reinicia Coucou; si sigue fallando, compílalo con `cargo build -p coucou-hook`.",
  "This is exactly what will change in your settings.json. Your own hooks are left untouched.":
    "Esto es exactamente lo que cambiará en tu settings.json. Tus propios hooks no se tocan.",
  "This removes Coucou's entries only. Your own hooks are left untouched.": "Esto quita solo las entradas de Coucou. Tus propios hooks no se tocan.",
  "Back up and write": "Copiar y escribir", "Back up and remove": "Copiar y quitar",
  "Codex CLI": "Codex CLI", "Install Codex hooks": "Instalar hooks de Codex", "Reinstall Codex hooks": "Reinstalar hooks de Codex",
  "Codex CLI isn't set up here yet. Install it and run it once to follow its sessions and approve them from the island too.":
    "Codex CLI aún no está configurado aquí. Instálalo y ejecútalo una vez para seguir sus sesiones y aprobarlas también desde la isla.",
  "Coucou's hooks are in Codex. Run /hooks in Codex once to review and trust them; its sessions then show up next to Claude Code's.":
    "Los hooks de Coucou están en Codex. Ejecuta /hooks en Codex una vez para revisarlos y confiar en ellos; después sus sesiones aparecen junto a las de Claude Code.",
  "Coucou can follow Codex CLI sessions and approve them from the island. Codex is never blocked if Coucou isn't running.":
    "Coucou puede seguir las sesiones de Codex CLI y aprobarlas desde la isla. Codex nunca se bloquea si Coucou no está abierto.",
  "Engine": "Motor", "Anthropic API key": "Clave de API de Anthropic", "Claude Code (your subscription)": "Claude Code (tu suscripción)",
  "Other provider (OpenAI, Gemini, Ollama…)": "Otro proveedor (OpenAI, Gemini, Ollama…)", "Provider": "Proveedor",
  "Server": "Servidor", "Model": "Modelo", "Load models": "Cargar modelos", "API key": "Clave de API",
  "Save key": "Guardar clave", "Saved. It never touches disk.": "Guardada. Nunca toca el disco.", "Key removed.": "Clave quitada.",
  "No key yet — the chat needs one.": "Aún no hay clave — el chat necesita una.",
  "Claude Code isn't installed (or not on PATH). Install it and sign in with `claude`, then reopen Settings.":
    "Claude Code no está instalado (o no está en el PATH). Instálalo e inicia sesión con `claude`, luego vuelve a abrir Ajustes.",
  "Token": "Token", "Secret key": "Clave secreta", "Instance URL": "URL de la instancia", "Integration token": "Token de integración",
  "Phone alerts": "Avisos al móvil", "Alerts": "Avisos", "Only when away": "Solo si no estoy", "Topic": "Tema",
  "New topic": "Nuevo tema", "Send a test": "Enviar prueba", "Sent. Check your phone.": "Enviado. Mira tu móvil.",
  "no keyboard or mouse for 2 min (Windows)": "sin teclado ni ratón durante 2 min (Windows)",
  "An approval still waiting after 20 seconds goes to your phone through ntfy (free app, no account). Subscribe to the topic in the app; it carries the project and the command, so keep it private.":
    "Una aprobación que sigue esperando tras 20 segundos llega a tu móvil por ntfy (app gratuita, sin cuenta). Suscríbete al tema en la app; lleva el proyecto y el comando, así que mantenlo en privado.",
  "GitHub (your token, or a signed-in gh) and Linear notifications that need you, behind the 🔔. Mochi peeks out when something new arrives.":
    "Las notificaciones de GitHub (tu token, o gh con sesión) y de Linear que te necesitan, detrás de la 🔔. Mochi se asoma cuando llega algo nuevo.",
  "Review requests": "Solicitudes de revisión", "Mentions": "Menciones", "Assignments": "Asignaciones", "Comments": "Comentarios",
  "Other updates": "Otras novedades", "Check daily": "Comprobar cada día", "Check now": "Comprobar ahora",
  "Island lives on": "La isla vive en", "Main display": "Pantalla principal", "Display under the cursor": "Pantalla bajo el cursor",
  "Launch at startup": "Abrir al iniciar sesión", "Open projects in": "Abrir proyectos en", "First one installed": "El primero instalado",
  "File manager (no editor found)": "Explorador de archivos (no hay editor)", "Language": "Idioma", "Same as the system": "Igual que el sistema",
  "Idle notch": "Notch en reposo", "a small notch stays at the top when the island hides": "una pequeña notch queda arriba cuando la isla se esconde",
  // WhaTicket
  "WhaTicket": "WhaTicket",
  "Auto-accept": "Auto-aceptar", "accept new tickets as you as soon as they arrive": "acepta los tickets nuevos a tu nombre en cuanto llegan",
  "Only from": "Solo de", "none ticked = any of your queues": "ninguna marcada = cualquiera de tus colas",
  "Only between": "Solo entre", "Any time — or e.g. 09:00-18:00": "A cualquier hora — o p. ej. 09:00-18:00",
  "Accept": "Aceptar", "No tickets waiting.": "No hay tickets esperando.",
  "Set up browser extension": "Configurar la extensión del navegador", "Set up again": "Configurar de nuevo",
  "Show folder": "Mostrar carpeta", "Not set up yet.": "Todavía no está configurada.",
  "Browser extension not set up": "Extensión del navegador sin configurar",
  "Open whaticket.com in Chrome or Edge": "Abre whaticket.com en Chrome o Edge",
  "Your queues show here once whaticket.com is open with the extension.": "Tus colas aparecen aquí cuando whaticket.com esté abierto con la extensión.",
  "Coucou reads your whaticket.com queue through a small Chrome / Edge extension that uses the session you already have open — no token, no password, and it never signs you out.":
    "Coucou lee tu cola de whaticket.com con una pequeña extensión de Chrome / Edge que usa la sesión que ya tienes abierta: sin token, sin contraseña, y nunca te cierra la sesión.",
  "Click Set up browser extension.": "Haz clic en Configurar la extensión del navegador.",
  "In Chrome open chrome://extensions (in Edge: edge://extensions) and turn on Developer mode.":
    "En Chrome abre chrome://extensions (en Edge: edge://extensions) y activa el Modo de desarrollador.",
  "Click Load unpacked and pick the extension folder shown above.": "Haz clic en Cargar descomprimida y elige la carpeta de la extensión que aparece arriba.",
  "Keep a whaticket.com tab open, and turn on the WhaTicket pill under Integrations.": "Deja una pestaña de whaticket.com abierta y activa la píldora de WhaTicket en Integraciones.",
  "Only while your whaticket.com tab is open. Never during Do not disturb, never group chats, never tickets an AI agent is handling. Coucou only assigns the ticket — it never writes to the customer.":
    "Solo mientras tu pestaña de whaticket.com esté abierta. Nunca en No molestar, nunca chats de grupo, nunca tickets que atiende un agente de IA. Coucou solo se asigna el ticket: nunca le escribe al cliente.",
  "Sign in to whaticket.com in Chrome or Edge.": "Inicia sesión en whaticket.com en Chrome o Edge.",
  "whaticket.com's session expired: use the tab once (or sign in again).": "La sesión de whaticket.com expiró: usa la pestaña una vez (o vuelve a iniciar sesión).",
  "Open whaticket.com in Chrome or Edge (with the Coucou extension) to accept from here.": "Abre whaticket.com en Chrome o Edge (con la extensión de Coucou) para aceptar desde aquí.",
  "No Chrome, Edge, Brave or Chromium found for this user": "No se encontró Chrome, Edge, Brave ni Chromium para este usuario",
  "Unknown ticket": "Ticket desconocido", "Someone already took that ticket.": "Alguien ya tomó ese ticket.",
  "Your WhaTicket profile isn't allowed to do that (403).": "Tu perfil de WhaTicket no tiene permiso para eso (403).",
  // Google
  "Google": "Google", "Gmail": "Gmail", "Disconnect": "Desconectar", "Connect Google…": "Conectar Google…",
  "Not connected yet.": "Aún no está conectado.", "Add your OAuth client first (steps above).": "Primero agrega tu cliente OAuth (pasos de arriba).",
  "Finish signing in in your browser…": "Termina de iniciar sesión en tu navegador…", "Connected.": "Conectado.",
  "Client ID": "ID de cliente", "Client secret": "Secreto del cliente", "Gmail shows": "Gmail muestra",
  "Gmail in the island and your Drive files in the chat (type @ and a file name). Read-only: Coucou never sends mail or changes files.":
    "Gmail en la isla y tus archivos de Drive en el chat (escribe @ y el nombre de un archivo). Solo lectura: Coucou nunca envía correos ni cambia archivos.",
  "One-time setup, free: in console.cloud.google.com create a project, turn on the Gmail API and the Google Drive API, set up the OAuth consent screen (External, add yourself as a test user, then Publish it so the sign-in doesn't expire every 7 days), and create an OAuth client ID of type \"Desktop app\". Paste its ID and secret here.":
    "Configuración única y gratuita: en console.cloud.google.com crea un proyecto, activa la API de Gmail y la de Google Drive, configura la pantalla de consentimiento OAuth (Externa, agrégate como usuario de prueba y luego Publícala para que la sesión no caduque cada 7 días) y crea un ID de cliente OAuth de tipo \"App de escritorio\". Pega aquí su ID y su secreto.",
  "A Gmail search, e.g. is:unread in:inbox, or is:important is:unread. Turn on the Gmail pill under Integrations.":
    "Una búsqueda de Gmail, p. ej. is:unread in:inbox o is:important is:unread. Activa la píldora de Gmail en Integraciones.",
  "Nothing new in your inbox.": "Nada nuevo en tu bandeja.", "(no subject)": "(sin asunto)",
  "Ask me anything… (/ skills, @ Drive)": "Pregúntame lo que quieras… (/ skills, @ Drive)",
  "Searching Drive…": "Buscando en Drive…", "Downloading…": "Descargando…", "No Drive file with that name.": "Ningún archivo de Drive con ese nombre.",
  "Connect Google in Settings → Google to search your Drive.": "Conecta Google en Ajustes → Google para buscar en tu Drive.",
  "Not connected to Google": "No conectado a Google", "Can't reach Google": "No se puede conectar con Google",
  "That file is over 10 MB — too big for the chat.": "Ese archivo pasa de 10 MB: demasiado grande para el chat.",
  "Nobody finished signing in within 5 minutes.": "Nadie terminó de iniciar sesión en 5 minutos.",
  "Paste your Google OAuth client ID first (see the steps above).": "Pega primero tu ID de cliente OAuth de Google (mira los pasos de arriba).",
  "Google signed Coucou out — connect again in Settings": "Google cerró la sesión de Coucou: vuelve a conectar en Ajustes",
  "Google refused (403): is the Gmail / Drive API turned on in your Google Cloud project?": "Google lo rechazó (403): ¿está activada la API de Gmail / Drive en tu proyecto de Google Cloud?",
  "Coucou can read Docs, Sheets, Slides and ordinary files — not this kind.": "Coucou puede leer Documentos, Hojas, Presentaciones y archivos normales, pero no este tipo.",
  // Skills
  "Skills": "Skills", "Search skills…": "Buscar skills…", "View": "Ver", "Folder": "Carpeta",
  "Open in the editor": "Abrir en el editor", "scripts": "scripts", "off": "apagada", "No description.": "Sin descripción.",
  "Personal": "Personal", "Project": "Proyecto", "Plugin": "Plugin", "Codex": "Codex",
  "No skills on this computer yet. Add one below.": "Aún no hay skills en esta computadora. Agrega una abajo.",
  "Add a skill": "Agregar una skill", "Install to": "Instalar en", "Preview": "Vista previa", "Install": "Instalar",
  "Folder, .zip / .skill file, or a GitHub link": "Carpeta, archivo .zip / .skill o un enlace de GitHub",
  "Or drop a skill folder or a .zip / .skill file on this window. You see what's inside before anything is installed.":
    "O suelta una carpeta de skill o un archivo .zip / .skill en esta ventana. Ves lo que contiene antes de instalar nada.",
  "Looking…": "Buscando…", "Installs to ": "Se instala en ",
  "It has scripts. Coucou never runs them, but Claude may when it uses the skill — read them first.":
    "Tiene scripts. Coucou nunca los ejecuta, pero Claude puede hacerlo al usar la skill: revísalos antes.",
  "A skill with this name is already there; installing replaces it (the old one is kept in Coucou's trash).":
    "Ya hay una skill con este nombre; instalar la reemplaza (la anterior se guarda en la papelera de Coucou).",
  "Installed. Claude Code picks it up in its next session.": "Instalada. Claude Code la usará desde su próxima sesión.",
  "New skill name": "Nombre de la nueva skill", "Create": "Crear",
  "What Claude Code and Codex can use on this computer: your own skills, each project's, and the ones that come with plugins. Turning one off moves it aside; nothing is deleted.":
    "Lo que Claude Code y Codex pueden usar en esta computadora: tus skills, las de cada proyecto y las que vienen con plugins. Apagar una la aparta; no se borra nada.",
  "Ask me anything… (/ for skills)": "Pregúntame lo que quieras… (/ para skills)", "What should it do?": "¿Qué debe hacer?",
  "Remove the skill": "Quitar la skill", "No skill matches.": "Ninguna skill coincide.",
  "No skills installed. Add some in Settings → Skills.": "No hay skills instaladas. Agrégalas en Ajustes → Skills.",
  "Voice": "Voz", "Read replies aloud": "Leer las respuestas en voz alta",
  "Install and restart": "Instalar y reiniciar", "Updating…": "Actualizando…",
  "You're already up to date.": "Ya estás al día.",
  "Speak your question": "Di tu pregunta", "Listening…": "Escuchando…",
  "I didn't catch that. Try again.": "No te he entendido. Inténtalo de nuevo.",
  "🎙 in the chat: say your question and Mochi sends it (Windows speech recognition; dictation needs online speech recognition on in Windows Settings → Privacy & security → Speech).":
    "🎙 en el chat: di tu pregunta y Mochi la envía (reconocimiento de voz de Windows; el dictado necesita el reconocimiento de voz en línea activado en Configuración → Privacidad y seguridad → Voz).",
  "Speaking your questions isn't available on Linux: it has no built-in speech recognition. Mochi can still read its replies aloud.":
    "Hablarle a Mochi no está disponible en Linux: no trae reconocimiento de voz. Mochi sí puede leer sus respuestas en voz alta.",
  "Speech recognition isn't available on Linux.": "El reconocimiento de voz no está disponible en Linux.",
  "No telemetry. Network requests only go to the services you configure yourself.":
    "Sin telemetría. Las peticiones de red solo van a los servicios que tú configuras.",
  "the Windows Credential Manager": "el Administrador de credenciales de Windows", "your keyring (Secret Service)": "tu llavero (Secret Service)",

  // do not disturb
  "For 30 minutes": "Durante 30 minutos", "For 1 hour": "Durante 1 hora", "For 3 hours": "Durante 3 horas",
  "Until tomorrow morning": "Hasta mañana por la mañana", "Until I turn it off": "Hasta que lo apague",
  "On until you turn it off": "Activado hasta que lo apagues", "until you turn it off": "hasta que lo apagues",

  // errors from the app
  "API key missing. Open settings.": "Falta la clave de API. Abre Ajustes.",
  "Claude Code isn't installed. Install it, or switch the chat to an API key in Settings.":
    "Claude Code no está instalado. Instálalo, o cambia el chat a una clave de API en Ajustes.",
  "Claude Code isn't signed in. Run `claude` in a terminal and sign in with /login.":
    "Claude Code no tiene sesión iniciada. Ejecuta `claude` en una terminal e inicia sesión con /login.",
  "Codex isn't installed. Install it, or pick another chat engine in Settings.":
    "Codex no está instalado. Instálalo, o elige otro motor de chat en Ajustes.",
  "Codex isn't signed in. Run `codex login` in a terminal, then ask again.":
    "Codex no tiene sesión iniciada. Ejecuta `codex login` en una terminal y vuelve a preguntar.",
  "Codex says you hit its usage limit. Wait a bit, or pick another chat engine.":
    "Codex dice que alcanzaste su límite de uso. Espera un poco o elige otro motor de chat.",
  "Gemini CLI isn't installed. Install it, or pick another chat engine in Settings.":
    "Gemini CLI no está instalado. Instálalo, o elige otro motor de chat en Ajustes.",
  "Gemini CLI isn't signed in. Run `gemini` in a terminal and sign in, then ask again.":
    "Gemini CLI no tiene sesión iniciada. Ejecuta `gemini` en una terminal, inicia sesión y vuelve a preguntar.",
  "Gemini says you hit its usage limit. Wait a bit, or pick another chat engine.":
    "Gemini dice que alcanzaste su límite de uso. Espera un poco o elige otro motor de chat.",
  "No ntfy topic yet": "Aún no hay tema de ntfy", "Can't reach GitHub": "No se puede conectar con GitHub",
  "Can't reach Linear": "No se puede conectar con Linear", "Invalid API key (401)": "Clave de API no válida (401)",
  "Add your Linear API key in Settings": "Añade tu clave de API de Linear en Ajustes",
};

/** Texts with something in them that changes: [pattern, Spanish with $1, $2…]. */
const PATTERNS: [RegExp, string][] = [
  [/^On until (\d\d:\d\d)$/, "Activado hasta las $1"],
  [/^On until tomorrow (\d\d:\d\d)$/, "Activado hasta mañana a las $1"],
  [/^until (\d\d:\d\d)$/, "hasta las $1"],
  [/^until tomorrow (\d\d:\d\d)$/, "hasta mañana a las $1"],
  [/^\+(\d+) waiting$/, "+$1 en espera"],
  [/^\+(\d+) more files?$/, "+$1 archivo(s) más"],
  [/^\+(\d+) more edits?$/, "+$1 cambio(s) más"],
  [/^(\d+) lines?$/, "$1 línea(s)"],
  [/^Auto-approve in (.+):$/, "Auto-aprobar en $1:"],
  [/^Install (\d+) skills$/, "Instalar $1 skills"],
  [/^Connected as (.+)\.$/, "Conectado como $1."],
  [/^Unread · (\d+)$/, "Sin leer · $1"],
  [/^Mail · (.+)$/, "Correo · $1"],
  [/^Ready for (.+)\. Extension folder: (.+)$/, "Lista para $1. Carpeta de la extensión: $2"],
  [/^Waiting (\d+) · Mine (\d+)( · Auto)?$/, "En espera $1 · Míos $2$3"],
  [/^Accepted · (.+)$/, "Aceptado · $1"],
  [/^Couldn't accept · (.+)$/, "No se pudo aceptar · $1"],
  [/^New ticket · (.+)$/, "Ticket nuevo · $1"],
  [/^Message · (.+)$/, "Mensaje · $1"],
  [/^(\d+) new$/, "$1 nuevos"],
  [/^(\d+) files: (.*)$/s, "$1 archivos: $2"],
  [/^Coucou (.+) is out — download$/, "Coucou $1 ya está disponible — descargar"],
  [/^Coucou (.+) is out — install and restart$/, "Coucou $1 ya está disponible — instalar y reiniciar"],
  [/^The update couldn't be installed: (.+)$/, "No se pudo instalar la actualización: $1"],
  [/^Coucou (.+) is out \(you have (.+)\)\.$/, "Coucou $1 ya está disponible (tienes $2)."],
  [/^You're up to date \((.+)\)\.$/, "Estás al día ($1)."],
  [/^You have (.+)\.$/, "Tienes $1."],
  [/^Key saved in (.+)\.$/, "Clave guardada en $1."],
  [/^Pick up to (\d+) pills to show next to Mochi — (\d+)\/(\d+) in use\. Keys are stored in (.+), never on disk\.$/,
    "Elige hasta $1 pastillas junto a Mochi — $2/$3 en uso. Las claves se guardan en $4, nunca en disco."],
  [/^Post to (.+)$/, "Publicar en $1"],
  [/^Posted on (.+) ✓$/, "Publicado en $1 ✓"],
  [/^Open (.+)$/, "Abrir $1"],
  [/^Uses (.+), signed in with your Claude plan\. No key needed; nothing about your sign-in is read or stored\.$/,
    "Usa $1, con la sesión de tu plan de Claude. No hace falta clave; nada de tu sesión se lee ni se guarda."],
  [/^Could not save: (.+)$/, "No se pudo guardar: $1"],
  [/^Could not remove: (.+)$/, "No se pudo quitar: $1"],
  [/^Could not write: (.+)$/, "No se pudo escribir: $1"],
  [/^Done\. Previous settings saved as (.+)\. Open a new Claude Code session to pick the hooks up\.$/,
    "Hecho. Ajustes anteriores guardados como $1. Abre una sesión nueva de Claude Code para que tome los hooks."],
  [/^Backup → (.+)$/, "Copia → $1"],
  [/^(\d+) tool calls?$/, "$1 herramienta(s)"],
  [/^(\d+) approvals?$/, "$1 aprobación(es)"],
  [/^(\d+) auto$/, "$1 automáticas"],
  [/^(\d+) needs? you$/, "$1 te necesita(n)"],
  [/^(\d+) messages$/, "$1 mensajes"],
  [/^(\d+) models — pick one in the field\.$/, "$1 modelos — elige uno en el campo."],
  [/^Uploading (.+)$/, "Subiendo $1"],
  [/^Assigned to you · (\d+)$/, "Asignado a ti · $1"],
  [/^Allowed from Coucou: (.+)$/, "Permitido desde Coucou: $1"],
  [/^Denied from Coucou: (.+)$/, "Denegado desde Coucou: $1"],
  [/^Left to the terminal: (.+)$/, "Respondido en la terminal: $1"],
  [/^Auto-approved \((.+)\): (.+)$/, "Auto-aprobado ($1): $2"],
  [/^(\d+)s$/, "$1 s"],
];

const RAW = ".chat-log, .code, .diff, .inbox-open .title, .path, .tl-time, [data-raw]";

function exact(s: string): string | null {
  return ES[s] ?? null;
}

/** English → Spanish for one text; unknown texts come back unchanged. */
export function t(text: string): string {
  if (lang === "en" || !text) return text;
  const lead = text.match(/^\s*/)?.[0] ?? "";
  const trail = text.match(/\s*$/)?.[0] ?? "";
  const s = text.trim();
  if (!s) return text;
  const hit = exact(s);
  if (hit != null) return lead + hit + trail;
  for (const [re, out] of PATTERNS) {
    const m = s.match(re);
    if (m) return lead + out.replace(/\$(\d)/g, (_, i) => t(m[Number(i)] ?? "")) + trail;
  }
  // "A · B": piece by piece (risk chips, steps, statuses).
  if (s.includes(" · ")) {
    const parts = s.split(" · ");
    const done = parts.map((p) => t(p));
    if (done.some((p, i) => p !== parts[i])) return lead + done.join(" · ") + trail;
  }
  return text;
}

function translateNode(node: Node) {
  if (node.nodeType === Node.TEXT_NODE) {
    const parent = node.parentElement;
    if (!parent || parent.closest(RAW)) return;
    const before = node.nodeValue ?? "";
    const after = t(before);
    if (after !== before) node.nodeValue = after;
    return;
  }
  if (node.nodeType !== Node.ELEMENT_NODE) return;
  const el = node as Element;
  if (el.closest(RAW)) return;
  for (const attr of ["title", "placeholder", "aria-label"]) {
    const v = el.getAttribute(attr);
    if (v) {
      const tv = t(v);
      if (tv !== v) el.setAttribute(attr, tv);
    }
  }
  if (el instanceof HTMLOptionElement) {
    const tv = t(el.text);
    if (tv !== el.text) el.text = tv;
    return;
  }
  for (const child of Array.from(el.childNodes)) translateNode(child);
}

/** Translates the page now and whatever is added or changed later. */
export function startTranslating(root: Node = document.body) {
  if (lang === "en") return;
  translateNode(root);
  new MutationObserver((records) => {
    for (const r of records) {
      if (r.type === "characterData") translateNode(r.target);
      else if (r.type === "attributes") translateNode(r.target);
      else r.addedNodes.forEach(translateNode);
    }
  }).observe(root, {
    subtree: true, childList: true, characterData: true,
    attributes: true, attributeFilter: ["title", "placeholder", "aria-label"],
  });
}

export const _test = { setLang: (l: Lang) => { lang = l; } };
