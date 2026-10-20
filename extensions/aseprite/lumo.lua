-- Lumo for Aseprite: ask Lumo about your sprite. The frame you're on (or the animation, as a
-- grid of frames) goes as an image, with the layers, tags, palette, selection and tool as text.
-- Talks to Lumo on this computer only, over its local WebSocket (127.0.0.1); the port and the
-- token are in the editor-bridge.json Lumo writes at launch:
--   macOS    ~/Library/Application Support/NotchBuddy/editor-bridge.json
--   Windows  %LOCALAPPDATA%\Coucou\editor-bridge.json
--   Linux    ~/.local/share/coucou/editor-bridge.json  ($XDG_DATA_HOME/coucou)
--
--   Edit → Lumo → Ask Lumo About This (Ctrl+Alt+L, Cmd+Alt+L on macOS), also in the cel's
--   right-click menu: Lumo opens its chat with the sprite attached.
--   While Lumo is open, the extension keeps it told about the sprite in front (no image), so
--   Lumo's own shortcut and dropping your character on Aseprite use it too.

local Lumo = {}

Lumo.MAX_LAYERS = 80
Lumo.MAX_PALETTE = 64
Lumo.MAX_DETAILS = 11000
Lumo.MAX_GRID_FRAMES = 16
Lumo.MIN_SNAPSHOT = 256   -- tiny sprites are scaled up (nearest neighbour) so the model sees pixels
Lumo.MAX_SNAPSHOT = 1600
Lumo.IDLE_CLOSE = 30      -- seconds
Lumo.CONTEXT_DELAY = 0.8  -- seconds between a change and telling Lumo

local plugin_ref = nil
local ws = nil
local ws_open = false
local queue = {}
local in_flight = {}
local retried_token = false
local token = nil
local idle_timer = nil
local context_timer = nil
local last_activity = 0
local last_context = nil

-- MARK: - Paths and the info file

local function env(name)
  local v = os.getenv(name)
  if v == nil or v == "" then return nil end
  return v
end

function Lumo.info_path()
  local join = app.fs.joinPath
  if app.os.macos then
    return join(env("HOME") or "", "Library", "Application Support", "NotchBuddy", "editor-bridge.json")
  elseif app.os.windows then
    return join(env("LOCALAPPDATA") or "", "Coucou", "editor-bridge.json")
  end
  local data = env("XDG_DATA_HOME")
  if data == nil or data:sub(1, 1) ~= "/" then data = join(env("HOME") or "", ".local", "share") end
  return join(data, "coucou", "editor-bridge.json")
end

function Lumo.read_info()
  local path = Lumo.info_path()
  if not app.fs.isFile(path) then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  local ok, info = pcall(json.decode, text)
  if not ok or type(info) ~= "table" then return nil end
  if type(info.token) ~= "string" or info.token == "" or not tonumber(info.port) then return nil end
  return info
end

function Lumo.available()
  return app.fs.isFile(Lumo.info_path())
end

-- MARK: - Sprite → payload

local function hex(c)
  return string.format("#%02x%02x%02x%s", c.red, c.green, c.blue, c.alpha < 255 and string.format("%02x", c.alpha) or "")
end

local function color_mode_name(mode)
  if mode == ColorMode.RGB then return "RGB" end
  if mode == ColorMode.GRAY or mode == ColorMode.GRAYSCALE then return "Grayscale" end
  if mode == ColorMode.INDEXED then return "Indexed" end
  if mode == ColorMode.TILEMAP then return "Tilemap" end
  return tostring(mode)
end

local function blend_name(mode)
  for name, value in pairs(BlendMode) do
    if value == mode then return name:lower() end
  end
  return tostring(mode)
end

local function ani_dir_name(dir)
  if dir == AniDir.FORWARD then return "forward" end
  if dir == AniDir.REVERSE then return "reverse" end
  if dir == AniDir.PING_PONG then return "ping-pong" end
  if AniDir.PING_PONG_REVERSE and dir == AniDir.PING_PONG_REVERSE then return "ping-pong reverse" end
  return tostring(dir)
end

local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

-- The folder the sprite belongs to: the nearest one up with a Godot project or a git repo, so
-- Lumo's chat can read the game around the art. Nil when there's none.
function Lumo.project_for(file)
  if not is_absolute(file) then return nil end
  local dir = app.fs.filePath(file)
  for _ = 1, 12 do
    if dir == nil or dir == "" then return nil end
    if app.fs.isFile(app.fs.joinPath(dir, "project.godot")) or app.fs.isDirectory(app.fs.joinPath(dir, ".git")) then
      return dir
    end
    local parent = app.fs.filePath(dir)
    if parent == dir then return nil end
    dir = parent
  end
  return nil
end

local function layer_lines(layers, depth, lines, counter, active)
  -- Aseprite lists layers bottom → top; the Layers panel shows top first.
  for i = #layers, 1, -1 do
    if counter.n >= Lumo.MAX_LAYERS then return end
    counter.n = counter.n + 1
    local layer = layers[i]
    local flags = {}
    if not layer.isVisible then flags[#flags + 1] = "hidden" end
    if layer.isGroup then flags[#flags + 1] = "group" end
    if layer.isTilemap then flags[#flags + 1] = "tilemap" end
    if layer.isReference then flags[#flags + 1] = "reference" end
    if layer.isBackground then flags[#flags + 1] = "background" end
    if not layer.isEditable then flags[#flags + 1] = "locked" end
    if layer.isImage and layer.opacity and layer.opacity < 255 then flags[#flags + 1] = "opacity " .. layer.opacity end
    if layer.isImage and layer.blendMode and layer.blendMode ~= BlendMode.NORMAL then
      flags[#flags + 1] = "blend " .. blend_name(layer.blendMode)
    end
    local mark = (layer == active) and "  ← active" or ""
    local extra = #flags > 0 and (" (" .. table.concat(flags, ", ") .. ")") or ""
    lines[#lines + 1] = string.rep("  ", depth + 1) .. layer.name .. extra .. mark
    if layer.isGroup then layer_lines(layer.layers, depth + 1, lines, counter, active) end
  end
end

function Lumo.details(sprite)
  local lines = {}
  local frame = app.frame or app.activeFrame
  local frame_number = frame and frame.frameNumber or 1
  local saved = is_absolute(sprite.filename)
  lines[#lines + 1] = string.format("Aseprite %s · %s%s", tostring(app.version),
    saved and sprite.filename or (sprite.filename .. " (not saved yet)"),
    sprite.isModified and " (unsaved changes)" or "")
  lines[#lines + 1] = string.format("Canvas %dx%d · %s · pixel ratio %dx%d", sprite.width, sprite.height,
    color_mode_name(sprite.colorMode), sprite.pixelRatio.width, sprite.pixelRatio.height)

  -- Frames and tags.
  local durations = {}
  for i, f in ipairs(sprite.frames) do
    if i > 32 then durations[#durations + 1] = "…" break end
    durations[#durations + 1] = string.format("%d", math.floor(f.duration * 1000 + 0.5))
  end
  lines[#lines + 1] = string.format("Frames: %d (current %d) · durations ms: %s", #sprite.frames, frame_number,
    table.concat(durations, ", "))
  if #sprite.tags > 0 then
    local tags = {}
    for _, tag in ipairs(sprite.tags) do
      local repeats = (tag.repeats and tag.repeats > 0) and string.format(" ×%d", tag.repeats) or ""
      tags[#tags + 1] = string.format("%s %d–%d %s%s", tag.name, tag.fromFrame.frameNumber, tag.toFrame.frameNumber,
        ani_dir_name(tag.aniDir), repeats)
    end
    lines[#lines + 1] = "Tags: " .. table.concat(tags, "; ")
  end
  local tag = app.tag or app.activeTag
  if tag then lines[#lines + 1] = "Current tag: " .. tag.name end

  -- Layers.
  lines[#lines + 1] = "Layers (top first):"
  local counter = { n = 0 }
  layer_lines(sprite.layers, 0, lines, counter, app.layer or app.activeLayer)
  if counter.n >= Lumo.MAX_LAYERS then lines[#lines + 1] = "  … (more layers)" end

  -- The cel under the user's hand.
  local cel = app.cel or app.activeCel
  if cel then
    local b = cel.bounds
    lines[#lines + 1] = string.format("Active cel: layer \"%s\", frame %d, at (%d, %d) size %dx%d%s",
      cel.layer.name, cel.frameNumber, b.x, b.y, b.width, b.height,
      (cel.opacity and cel.opacity < 255) and (", opacity " .. cel.opacity) or "")
  end

  -- Selection.
  local sel = sprite.selection
  if sel and not sel.isEmpty then
    local b = sel.bounds
    lines[#lines + 1] = string.format("Selection: (%d, %d) size %dx%d", b.x, b.y, b.width, b.height)
  end

  -- Palette (the frame's).
  local palette = sprite.palettes[1]
  if palette then
    local colors = {}
    for i = 0, math.min(#palette, Lumo.MAX_PALETTE) - 1 do colors[#colors + 1] = hex(palette:getColor(i)) end
    lines[#lines + 1] = string.format("Palette: %d colors%s: %s", #palette,
      #palette > Lumo.MAX_PALETTE and (" (first " .. Lumo.MAX_PALETTE .. ")") or "", table.concat(colors, " "))
  end

  -- Tool and colors.
  local tool = app.tool or app.activeTool
  local brush = app.brush or app.activeBrush
  local fg, bg = app.fgColor, app.bgColor
  local tool_line = "Tool: " .. (tool and tool.id or "?")
  if brush then tool_line = tool_line .. string.format(" · brush %d px", brush.size) end
  if fg then tool_line = tool_line .. " · foreground " .. hex(fg) end
  if bg then tool_line = tool_line .. " · background " .. hex(bg) end
  lines[#lines + 1] = tool_line

  if #sprite.slices > 0 then
    local names = {}
    for i, slice in ipairs(sprite.slices) do
      if i > 20 then names[#names + 1] = "…" break end
      names[#names + 1] = slice.name
    end
    lines[#lines + 1] = "Slices: " .. table.concat(names, ", ")
  end
  if #app.sprites > 1 then
    local others = {}
    for _, s in ipairs(app.sprites) do
      if s ~= sprite then others[#others + 1] = app.fs.fileName(s.filename) end
    end
    lines[#lines + 1] = "Other open sprites: " .. table.concat(others, ", ")
  end

  local text = table.concat(lines, "\n")
  if #text > Lumo.MAX_DETAILS then text = text:sub(1, Lumo.MAX_DETAILS) .. "\n…" end
  return text
end

-- Frames to show: the current tag's, else all (at most MAX_GRID_FRAMES).
local function snapshot_frames(sprite)
  local tag = app.tag or app.activeTag
  local first, last = 1, #sprite.frames
  if tag then first, last = tag.fromFrame.frameNumber, tag.toFrame.frameNumber end
  local list = {}
  for i = first, last do
    if #list >= Lumo.MAX_GRID_FRAMES then break end
    list[#list + 1] = i
  end
  return list
end

-- A PNG in the temp folder: the current frame, or the frames in a grid when there's an
-- animation. Returns the path and a line describing it for the model.
function Lumo.snapshot(sprite)
  local frame = app.frame or app.activeFrame
  local current = frame and frame.frameNumber or 1
  local frames = snapshot_frames(sprite)
  local w, h = sprite.width, sprite.height
  local columns = #frames > 1 and math.min(#frames, 4) or 1
  local rows = #frames > 1 and math.ceil(#frames / columns) or 1
  if #frames <= 1 then frames = { current } end
  local gap = #frames > 1 and 1 or 0
  local sheet = Image(columns * w + (columns - 1) * gap, rows * h + (rows - 1) * gap, ColorMode.RGB)
  local one = Image(w, h, ColorMode.RGB)
  for i, number in ipairs(frames) do
    one:clear()
    one:drawSprite(sprite, number)
    local col = (i - 1) % columns
    local row = (i - 1) // columns
    sheet:drawImage(one, Point(col * (w + gap), row * (h + gap)))
  end
  -- Scale: whole pixels up for small art, down (rarely) for huge canvases.
  local longest = math.max(sheet.width, sheet.height)
  local scale = 1
  if longest < Lumo.MIN_SNAPSHOT then scale = math.ceil(Lumo.MIN_SNAPSHOT / longest) end
  local width, height = sheet.width * scale, sheet.height * scale
  if math.max(width, height) > Lumo.MAX_SNAPSHOT then
    local f = Lumo.MAX_SNAPSHOT / math.max(width, height)
    width, height = math.max(1, math.floor(width * f)), math.max(1, math.floor(height * f))
  end
  if width ~= sheet.width or height ~= sheet.height then sheet:resize(width, height) end
  local path = app.fs.joinPath(app.fs.tempPath, string.format("lumo-aseprite-%d.png", os.time()))
  sheet:saveAs(path)
  if not app.fs.isFile(path) then return nil, nil end
  local about
  if #frames > 1 then
    about = string.format("The snapshot shows frames %d–%d in reading order, %d per row (current frame: %d), scaled %dx.",
      frames[1], frames[#frames], columns, current, scale)
  else
    about = string.format("The snapshot shows frame %d, scaled %dx.", current, scale)
  end
  return path, about
end

function Lumo.gather(with_image)
  local sprite = app.sprite or app.activeSprite
  if not sprite then return nil end
  local frame = app.frame or app.activeFrame
  local file = sprite.filename
  if not is_absolute(file) then
    -- Not saved yet: a name in the temp folder so Lumo still has a place to stand.
    file = app.fs.joinPath(app.fs.tempPath, app.fs.fileName(file) .. ".aseprite")
  end
  local payload = {
    appName = "Aseprite",
    file = file,
    language = "aseprite",
    line = frame and frame.frameNumber or 1,
  }
  local project = Lumo.project_for(file)
  if project then payload.workspace = project end
  local details = Lumo.details(sprite)
  if with_image then
    local ok, path, about = pcall(Lumo.snapshot, sprite)
    if ok and path then
      payload.image = path
      details = details .. "\n" .. about
    end
  end
  payload.details = details
  return payload
end

-- MARK: - Talking to Lumo

local function notify(message)
  if app.isUIAvailable then app.tip(message) else print(message) end
end

local function close_socket()
  if ws then ws:close() end
  ws, ws_open, in_flight = nil, false, {}
end

local function flush()
  if not (ws and ws_open) then return end
  while #queue > 0 do
    local message = table.remove(queue, 1)
    local wire = {}
    for k, v in pairs(message) do wire[k] = v end
    wire.token = token
    ws:sendText(json.encode(wire))
    in_flight[#in_flight + 1] = message
  end
  last_activity = os.time()
end

local function on_answer(text)
  local sent = table.remove(in_flight, 1)
  local ok_parse, answer = pcall(json.decode, text)
  if not ok_parse or type(answer) ~= "table" then return end
  if answer.ok then
    retried_token = false
    return
  end
  local err = tostring(answer.error or "")
  -- Lumo restarted (new token): read it again and retry once.
  if err:find("^bad token") and not retried_token and sent then
    retried_token = true
    table.insert(queue, 1, sent)
    close_socket()
    Lumo.connect()
    return
  end
  if sent and sent.hook_event_name == "EditorAsk" then notify("Lumo: " .. err) end
end

local function on_message(kind, data, err)
  if kind == WebSocketMessageType.OPEN then
    ws_open = true
    flush()
  elseif kind == WebSocketMessageType.TEXT then
    on_answer(data)
  elseif kind == WebSocketMessageType.CLOSE then
    ws_open = false
  elseif kind == WebSocketMessageType.ERROR then
    ws_open = false
  end
end

function Lumo.connect()
  if ws then return true end
  local info = Lumo.read_info()
  if not info then return false end
  token = info.token
  ws = WebSocket {
    url = string.format("ws://127.0.0.1:%d", math.floor(tonumber(info.port))),
    onreceive = on_message,
    deflate = false,
    minreconnectwait = 1,
    maxreconnectwait = 5,
  }
  ws:connect()
  last_activity = os.time()
  if idle_timer == nil then
    idle_timer = Timer {
      interval = 5.0,
      ontick = function()
        -- Nothing to say for a while: hang up (Aseprite would keep reconnecting otherwise).
        if ws and #queue == 0 and #in_flight == 0 and os.time() - last_activity > Lumo.IDLE_CLOSE then
          close_socket()
          idle_timer:stop()
        end
      end,
    }
  end
  if not idle_timer.isRunning then idle_timer:start() end
  return true
end

function Lumo.send(event, payload)
  if not Lumo.connect() then return false end
  local message = {}
  for k, v in pairs(payload) do message[k] = v end
  message.hook_event_name = event
  if event == "EditorContext" then
    for i = #queue, 1, -1 do
      if queue[i].hook_event_name == "EditorContext" then table.remove(queue, i) end
    end
  end
  queue[#queue + 1] = message
  while #queue > 4 do table.remove(queue, 1) end
  last_activity = os.time()
  flush()
  return true
end

function Lumo.ask()
  local payload = Lumo.gather(Lumo.prefs().snapshot ~= false)
  if not payload then
    notify("Lumo: open a sprite first.")
    return
  end
  if not Lumo.send("EditorAsk", payload) then
    app.alert { title = "Lumo", text = "Lumo isn't running. Open Lumo and try again." }
  end
end

function Lumo.share_context()
  if Lumo.prefs().share == false or not Lumo.available() then return end
  local payload = Lumo.gather(false)
  if not payload then return end
  local text = json.encode(payload)
  if text == last_context then return end
  last_context = text
  Lumo.send("EditorContext", payload)
end

function Lumo.context_changed()
  if Lumo.prefs().share == false or not Lumo.available() then return end
  if context_timer == nil then
    context_timer = Timer {
      interval = Lumo.CONTEXT_DELAY,
      ontick = function()
        context_timer:stop()
        Lumo.share_context()
      end,
    }
  end
  context_timer:stop()
  context_timer:start()
end

function Lumo.prefs()
  return plugin_ref and plugin_ref.preferences or {}
end

function Lumo.settings_dialog()
  local prefs = Lumo.prefs()
  local dlg = Dialog { title = "Lumo" }
  dlg:check { id = "snapshot", text = "Attach an image of the frame (or the animation) when asking",
              selected = prefs.snapshot ~= false }
  dlg:newrow()
  dlg:check { id = "share", text = "Keep Lumo told about the sprite in front (no image)",
              selected = prefs.share ~= false }
  dlg:separator()
  dlg:label { text = Lumo.available() and "Lumo is running." or "Lumo isn't running." }
  dlg:button { id = "ok", text = "OK", focus = true }
  dlg:button { id = "cancel", text = "Cancel" }
  dlg:show()
  if dlg.data.ok then
    prefs.snapshot = dlg.data.snapshot
    prefs.share = dlg.data.share
  end
end

-- MARK: - Extension entry points

local site_listener = nil

function init(plugin)
  plugin_ref = plugin
  if plugin.preferences.snapshot == nil then plugin.preferences.snapshot = true end
  if plugin.preferences.share == nil then plugin.preferences.share = true end

  plugin:newMenuGroup { id = "lumo_menu", title = "Lumo", group = "edit_fx" }
  plugin:newCommand {
    id = "LumoAsk",
    title = "Ask Lumo About This",
    group = "lumo_menu",
    onclick = Lumo.ask,
    onenabled = function() return (app.sprite or app.activeSprite) ~= nil end,
  }
  plugin:newCommand {
    id = "LumoSettings",
    title = "Lumo Settings…",
    group = "lumo_menu",
    onclick = Lumo.settings_dialog,
  }
  plugin:newCommand {
    id = "LumoAskCel",
    title = "Ask Lumo About This",
    group = "cel_popup_properties",
    onclick = Lumo.ask,
  }
  site_listener = app.events:on("sitechange", Lumo.context_changed)
end

function exit(plugin)
  if site_listener then app.events:off(site_listener) end
  if context_timer then context_timer:stop() end
  if idle_timer then idle_timer:stop() end
  close_socket()
end

-- For the tests (tests/run.lua): the module itself.
return Lumo
