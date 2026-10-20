-- Tests for lumo.lua against a stand-in for Aseprite's Lua API (what the extension uses only).
-- Run from the repo: lua5.4 extensions/aseprite/tests/run.lua

local here = arg[0]:match("^(.*)/tests/run.lua$") or "extensions/aseprite"
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "/coucou'")

-- MARK: - A tiny JSON (Aseprite has `json` built in)

local function encode(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  if #v > 0 or next(v) == nil then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = encode(x) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = encode(k) .. ":" .. encode(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function decode(s)
  local pos = 1
  local function ws() pos = s:find("[^%s]", pos) or #s + 1 end
  local value
  local function str()
    local out, i = {}, pos + 1
    while true do
      local c = s:sub(i, i)
      if c == '"' then pos = i + 1 return table.concat(out) end
      if c == "\\" then
        local n = s:sub(i + 1, i + 1)
        out[#out + 1] = ({ n = "\n", t = "\t", r = "\r" })[n] or n
        i = i + 2
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      local o = {}
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return o end
      while true do
        ws()
        local k = str()
        ws(); pos = pos + 1 -- :
        o[k] = value()
        ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return o end
      end
    elseif c == "[" then
      local a = {}
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return a end
      while true do
        a[#a + 1] = value()
        ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return a end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    end
    local num = s:match("^-?[%d%.eE+-]+", pos)
    pos = pos + #num
    return tonumber(num)
  end
  return value()
end
json = { encode = encode, decode = decode }

-- MARK: - Aseprite stand-ins

ColorMode = { RGB = 0, GRAY = 1, INDEXED = 2, TILEMAP = 4 }
BlendMode = { NORMAL = 0, MULTIPLY = 1, SCREEN = 2 }
AniDir = { FORWARD = 0, REVERSE = 1, PING_PONG = 2, PING_PONG_REVERSE = 3 }
WebSocketMessageType = { TEXT = 0, BINARY = 1, OPEN = 2, CLOSE = 3, ERROR = 4 }

function Point(x, y) return { x = x, y = y } end

local images = {}
function Image(w, h, mode)
  local img = { width = w, height = h, mode = mode, drawn = {} }
  function img:clear() self.drawn = {} end
  function img:drawSprite(sprite, n) self.drawn[#self.drawn + 1] = n end
  function img:drawImage(other, at) self.drawn[#self.drawn + 1] = at end
  function img:resize(nw, nh) self.width, self.height = nw, nh end
  function img:saveAs(path)
    local f = assert(io.open(path, "wb"))
    f:write("\137PNG\r\n\26\n")
    f:close()
    self.saved = path
  end
  images[#images + 1] = img
  return img
end

local timers = {}
function Timer(t)
  local timer = { interval = t.interval, ontick = t.ontick, isRunning = false }
  function timer:start() self.isRunning = true end
  function timer:stop() self.isRunning = false end
  timers[#timers + 1] = timer
  return timer
end
local function tick_all()
  for _, t in ipairs(timers) do if t.isRunning then t.ontick() end end
end

local sockets = {}
function WebSocket(opts)
  local sock = { url = opts.url, onreceive = opts.onreceive, sent = {}, closed = false }
  function sock:connect() end
  function sock:close() self.closed = true end
  function sock:sendText(text) self.sent[#self.sent + 1] = decode(text) end
  sockets[#sockets + 1] = sock
  return sock
end

local function color(r, g, b, a) return { red = r, green = g, blue = b, alpha = a or 255 } end
local function layer(name, opts)
  local l = { name = name, isVisible = true, isEditable = true, isImage = true, isGroup = false,
              opacity = 255, blendMode = BlendMode.NORMAL, layers = {} }
  for k, v in pairs(opts or {}) do l[k] = v end
  return l
end

local body = layer("Body")
local head = layer("Head", { opacity = 128, blendMode = BlendMode.MULTIPLY })
local group = layer("Character", { isImage = false, isGroup = true, layers = { body, head } })
local bg = layer("Background", { isBackground = true })
local frames = {}
for i = 1, 6 do frames[i] = { frameNumber = i, duration = 0.1 } end
local run = { name = "run", fromFrame = frames[2], toFrame = frames[5], aniDir = AniDir.PING_PONG, repeats = 0 }

local game = tmp .. "/my-game"
os.execute("mkdir -p '" .. game .. "/art'")
io.open(game .. "/project.godot", "w"):close()

local palette = { n = 3 }
setmetatable(palette, { __len = function() return 3 end })
function palette:getColor(i) return ({ [0] = color(0, 0, 0, 0), color(255, 0, 64), color(16, 32, 48) })[i] end

local sprite = {
  filename = game .. "/art/hero.aseprite", isModified = true,
  width = 32, height = 24, colorMode = ColorMode.INDEXED, pixelRatio = { width = 1, height = 1 },
  frames = frames, tags = { run }, layers = { bg, group }, slices = {},
  selection = { isEmpty = false, bounds = { x = 2, y = 3, width = 10, height = 8 } },
  palettes = { palette },
}

local listeners = {}
app = {
  version = "1.3.18.6", isUIAvailable = true,
  os = { macos = false, windows = false, linux = true },
  sprite = sprite, frame = frames[3], tag = run, layer = head,
  cel = { layer = head, frameNumber = 3, bounds = { x = 4, y = 0, width = 12, height = 10 }, opacity = 255 },
  tool = { id = "pencil" }, brush = { size = 1 }, fgColor = color(255, 0, 64), bgColor = color(0, 0, 0),
  sprites = { sprite },
  events = { on = function(_, name, f) listeners[#listeners + 1] = { name, f } return #listeners end, off = function() end },
  tips = {}, alerts = {},
}
function app.tip(text) app.tips[#app.tips + 1] = text end
function app.alert(t) app.alerts[#app.alerts + 1] = t end
app.fs = {
  tempPath = tmp,
  joinPath = function(...) return table.concat({ ... }, "/") end,
  filePath = function(p) return p:match("^(.*)/[^/]*$") or "" end,
  fileName = function(p) return p:match("([^/]*)$") end,
  isFile = function(p) local f = io.open(p, "r") if f then f:close() return true end return false end,
  isDirectory = function(p) return os.execute("test -d '" .. p .. "'") == true end,
}

-- Lumo's info file lives in $XDG_DATA_HOME/coucou on Linux.
local real_getenv = os.getenv
os.getenv = function(name) if name == "XDG_DATA_HOME" then return tmp end return real_getenv(name) end
local function write_info(token)
  local f = assert(io.open(tmp .. "/coucou/editor-bridge.json", "w"))
  f:write(encode({ port = 47615, token = token, version = 1 }))
  f:close()
end

-- MARK: - Tests

local Lumo = dofile(here .. "/lumo.lua")
local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else print("FAIL " .. what) failures = failures + 1 end
end

local plugin = { preferences = {}, commands = {}, groups = {} }
function plugin:newCommand(c) self.commands[c.id] = c end
function plugin:newMenuGroup(g) self.groups[g.id] = g end
init(plugin)

check(plugin.commands.LumoAsk and plugin.groups.lumo_menu, "registers Edit → Lumo → Ask Lumo About This")
check(plugin.commands.LumoAskCel ~= nil, "adds Ask Lumo to the cel menu")
check(plugin.preferences.snapshot == true and plugin.preferences.share == true, "defaults: snapshot and sharing on")
check(Lumo.info_path() == tmp .. "/coucou/editor-bridge.json", "finds editor-bridge.json in XDG_DATA_HOME")

-- Lumo not running.
plugin.commands.LumoAsk.onclick()
check(#app.alerts == 1 and #sockets == 0, "says Lumo isn't running, opens nothing")

-- Lumo running.
write_info("secret-token-1")
plugin.commands.LumoAsk.onclick()
check(#sockets == 1 and sockets[1].url == "ws://127.0.0.1:47615", "connects to 127.0.0.1 on Lumo's port")
check(#sockets[1].sent == 0, "waits for the connection before sending")
sockets[1].onreceive(WebSocketMessageType.OPEN, "", "")
local m = sockets[1].sent[1]
check(m and m.hook_event_name == "EditorAsk" and m.token == "secret-token-1", "sends EditorAsk with the token")
check(m.appName == "Aseprite" and m.file == sprite.filename and m.language == "aseprite", "file and app")
check(m.workspace == game, "workspace is the Godot project around the sprite")
check(m.line == 3, "line is the current frame")
check(m.image and app.fs.isFile(m.image), "snapshot PNG written")
check(m.details:find("Canvas 32x24 · Indexed", 1, true), "details: canvas")
check(m.details:find("Frames: 6 (current 3)", 1, true), "details: frames")
check(m.details:find("run 2–5 ping-pong", 1, true), "details: tags")
check(m.details:find("Character (group)", 1, true) and m.details:find("Head (opacity 128, blend multiply)  ← active", 1, true),
  "details: layer tree, flags and active layer")
check(m.details:find("Character", 1, true) < m.details:find("Background", 1, true), "layers top first")
check(m.details:find("Selection: (2, 3) size 10x8", 1, true), "details: selection")
check(m.details:find("#ff0040", 1, true) and m.details:find("#00000000", 1, true), "details: palette with alpha")
check(m.details:find("frames 2–5 in reading order, 4 per row (current frame: 3)", 1, true), "details: describes the grid of the tag's frames")
local sheet
for _, img in ipairs(images) do if img.saved == m.image then sheet = img end end
check(sheet.width >= 256 or sheet.height >= 256, "small art scaled up")
check(sheet.width % (4 * 32 + 3) == 0, "scaled by whole pixels")

-- Lumo answers.
sockets[1].onreceive(WebSocketMessageType.TEXT, '{"ok":true}', "")
check(#app.tips == 0, "no tip when Lumo takes it")

-- Lumo restarted with a new token: read it again and resend once.
write_info("secret-token-2")
plugin.commands.LumoAsk.onclick()
sockets[1].onreceive(WebSocketMessageType.TEXT, '{"ok":false,"error":"bad token: read it again"}', "")
check(sockets[1].closed and #sockets == 2, "reconnects after a bad token")
sockets[2].onreceive(WebSocketMessageType.OPEN, "", "")
check(sockets[2].sent[1] and sockets[2].sent[1].token == "secret-token-2" and sockets[2].sent[1].hook_event_name == "EditorAsk",
  "resends with the new token")
sockets[2].onreceive(WebSocketMessageType.TEXT, '{"ok":false,"error":"bad token: read it again"}', "")
check(#sockets == 2, "retries only once")

-- Context sharing on site change, no image, deduped.
for _, l in ipairs(listeners) do if l[1] == "sitechange" then l[2]() end end
tick_all()
local ctx = sockets[2].sent[#sockets[2].sent]
check(ctx.hook_event_name == "EditorContext" and ctx.image == nil, "sitechange shares context without an image")
local count = #sockets[2].sent
for _, l in ipairs(listeners) do if l[1] == "sitechange" then l[2]() end end
tick_all()
check(#sockets[2].sent == count, "unchanged context isn't sent again")
plugin.preferences.share = false
app.frame = frames[4]
for _, l in ipairs(listeners) do if l[1] == "sitechange" then l[2]() end end
tick_all()
check(#sockets[2].sent == count, "sharing off: nothing sent")

-- One frame, unsaved sprite.
sprite.frames = { frames[1] }
sprite.tags = {}
app.tag = nil
app.frame = frames[1]
sprite.filename = "Sprite-0001"
local p = Lumo.gather(true)
check(p.file == tmp .. "/Sprite-0001.aseprite" and p.workspace == nil, "unsaved sprite: a temp path, no workspace")
check(p.details:find("(not saved yet)", 1, true) and p.details:find("The snapshot shows frame 1, scaled 8x.", 1, true),
  "unsaved sprite: says so, single frame scaled")

-- No sprite.
app.sprite = nil
check(Lumo.gather(true) == nil, "no sprite: nothing to send")
plugin.commands.LumoAsk.onclick()
check(app.tips[#app.tips] == "Lumo: open a sprite first.", "no sprite: tip")

exit(plugin)
os.execute("rm -rf '" .. tmp .. "'")
print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
