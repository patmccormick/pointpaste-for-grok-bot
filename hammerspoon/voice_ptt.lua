-- PointTalk: hold-to-talk -> whisper.cpp (on-device) -> Grok Bot webhook
-- Install as ~/.hammerspoon/voice_ptt.lua and add  require("voice_ptt")  to ~/.hammerspoon/init.lua
-- Trigger: hold RIGHT Option alone (keycode 61) to talk, release to send.
--          Any other key/modifier/mouse click during the hold cancels (so Option+letter still types).
-- Escape hatch: ctrl+alt+cmd+Escape (force reset) or the menubar icon.
local M = {}

local HOME        = os.getenv("HOME")
local FFMPEG      = (hs.fs.attributes("/opt/homebrew/bin/ffmpeg") and "/opt/homebrew/bin/ffmpeg") or "/usr/local/bin/ffmpeg"
local WHISPER     = HOME .. "/.hammerspoon/local/bin/whisper-cli"
local NOWPLAYING  = HOME .. "/.hammerspoon/local/bin/nowplaying-cli"
local MODEL       = HOME .. "/.hammerspoon/models/ggml-base.en.bin"
local CONFIG      = HOME .. "/.hammerspoon/voice-webhook.json"
local LOGFILE     = HOME .. "/.hammerspoon/voice_ptt.log"
local OSASCRIPT   = "/usr/bin/osascript"
local PAGE_TIMEOUT= 2     -- s; Brave Automation must never delay recording
local PAGE_SCRIPT = [[
tell application "Brave Browser"
  set tabData to get {URL, title} of active tab of front window
  return (item 1 of tabData) & (ASCII character 1) & (item 2 of tabData)
end tell
]]
local MODS        = { "ctrl", "alt", "cmd" }   -- only for force-reset (ctrl+alt+cmd+Escape)
local RALT_KEYCODE= 61
local RALT_MASK   = 0x40  -- NX_DEVICERALTKEYMASK in raw flags
local FEEDBACK_DELAY = 0.25 -- s; show pill / pause media only once the hold looks intentional
local TAP_CHECK   = 5     -- s; eventtap health check interval
local MIN_HOLD    = 0.4   -- s; shorter presses are ignored
local MAX_REC     = 60    -- s; auto-stop
local FFMPEG_GRACE= 3     -- s after SIGINT before terminate/kill
local WHISPER_MAX = 60    -- s watchdog
local HTTP_MAX    = 20    -- s watchdog
local PP_WINDOW   = 300   -- s; a PointTalk copy this recent is attached to the next voice message
local PP_MAX      = 20000 -- bytes; cap for the "context" field
-- The PointTalk extension ("Copy for Grok Bot", extension/ in this kit) copies markdown
-- starting with this header (see packMarkdown() in extension/pick-mode.js).
local PP_HEADER   = "### Element pack"

local log = hs.logger.new("voice_ptt", "info")

-- Module-level state (keeps hs.task / timers / taps referenced => not GC'd)
local S = { state = "idle", gen = 0 }
local notify
-- S.pp = { text = <payload>, at = <epoch secs> } : last PointTalk copy (never logged); nil once sent/expired
M._S = S

local function flog(level, msg)
  msg = tostring(msg)
  if level == "e" then log.e(msg) elseif level == "w" then log.w(msg) else log.i(msg) end
  local f = io.open(LOGFILE, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), " [", level, "] [", S.state, "] ", msg, "\n"); f:close() end
end

local function stopTimer(name) if S[name] then S[name]:stop(); S[name] = nil end end
local function stopAllTimers()
  for _, n in ipairs({ "maxTimer", "killTimer", "killTimer2", "whisperTimer", "httpTimer", "feedbackTimer", "pageTimer" }) do stopTimer(n) end
end

-- ---------------------------------------------------------------------------
-- PointTalk capture tracking. Only clipboard text in PointTalk format is ever kept;
-- anything else (passwords etc.) is never stored, logged, or sent.
-- ---------------------------------------------------------------------------
local function isPointTalk(s)
  if type(s) ~= "string" or #s < #PP_HEADER then return false end
  local body = s:gsub("^%s+", "")
  if body:sub(1, #PP_HEADER) ~= PP_HEADER then return false end
  -- required structure lines produced by packMarkdown()
  return body:find("\n%*%*Page:%*%* ") ~= nil and body:find("\n%*%*Target:%*%* ") ~= nil
end

local function ppPending()
  local pp = S.pp
  if pp and (hs.timer.secondsSinceEpoch() - pp.at) <= PP_WINDOW then return pp end
  return nil
end

-- Truncate to <= max bytes without splitting a UTF-8 sequence.
local function utf8Cap(s, max)
  if #s <= max then return s end
  local cut = max
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end   -- next byte starts a char: safe cut
    cut = cut - 1
  end
  return s:sub(1, cut)
end

local function refreshTitle()
  if not M.menubar then return end
  local icons = { idle = "🎙", recording = "🔴", stopping = "⏹", processing = "⏳", sending = "📤" }
  M.menubar:setTitle((icons[S.state] or "🎙") .. (ppPending() and "📎" or ""))
end

local function setState(st)
  if S.state ~= st then flog("i", "state -> " .. st) end
  S.state = st
  refreshTitle()
end

local function ppClear(why)
  if S.ppExpiry then S.ppExpiry:stop(); S.ppExpiry = nil end
  if S.pp then flog("i", "PointTalk capture cleared (" .. why .. ")") end
  S.pp = nil
  refreshTitle()
end

-- Called with new clipboard text (watcher). Non-PointTalk content is ignored and not retained.
local function ppOnClipboard(content, at)
  if not isPointTalk(content) then return false end
  if S.ppExpiry then S.ppExpiry:stop(); S.ppExpiry = nil end
  S.pp = { text = content, at = at or hs.timer.secondsSinceEpoch() }
  flog("i", "PointTalk capture copied (" .. #content .. " bytes)")
  S.ppExpiry = hs.timer.doAfter(PP_WINDOW + 1, function()
    pcall(function() S.ppExpiry = nil; if S.pp and not ppPending() then ppClear("expired"); notify("📎 PointTalk capture expired", 2) end end)
  end)
  refreshTitle()
  notify("📎 PointTalk ready — hold right Option to talk", 3)
  return true
end

local function pageHost(url)
  local host = tostring(url):match("^[%a][%w+.-]*://([^/%?#]+)") or ""
  host = host:gsub("^.-@", ""):gsub(":%d+$", "")
  return host
end

-- Capture Brave's active tab at press time without ever delaying recording.
-- Only the host is logged; URL/title are retained solely for the next body.
local function capturePage(gen)
  local frontmost = false
  local okApp, app = pcall(hs.application.frontmostApplication)
  if okApp and app then
    local okBundle, bundle = pcall(function() return app:bundleID() end)
    frontmost = okBundle and bundle == "com.brave.Browser"
  end
  local braveRunning = frontmost
  if not braveRunning then
    pcall(function() braveRunning = hs.application.get("com.brave.Browser") ~= nil end)
  end
  if not braveRunning then return end

  local task
  task = hs.task.new(OSASCRIPT, function(code, out, errOut)
    if S.pageTask ~= task then return end
    stopTimer("pageTimer"); S.pageTask = nil
    if gen ~= S.gen then return end
    if code ~= 0 then
      local e = tostring(errOut):lower()
      if e:find("not authorized", 1, true) or e:find("not permitted", 1, true) or e:find("automation", 1, true) or e:find("-1743", 1, true) then
        flog("w", "page capture permission error")
      else
        flog("w", "page capture failed")
      end
      return
    end
    local url, title = tostring(out):match("^(.-)\1(.*)")
    if not url then flog("w", "page capture returned no tab data"); return end
    url = url:gsub("[\r\n]+$", "")
    title = title:gsub("[\r\n]+$", "")
    if url == "" then flog("w", "page capture returned no URL"); return end
    S.page = { url = url, title = utf8Cap(title, 300), frontmost = frontmost }
    local host = pageHost(url)
    flog("i", "page host: " .. (host ~= "" and host or "(none)"))
  end, { "-e", PAGE_SCRIPT })
  if not task then flog("w", "page capture could not start"); return end
  S.pageTask = task
  S.pageTimer = hs.timer.doAfter(PAGE_TIMEOUT, function()
    if S.pageTask ~= task then return end
    S.pageTimer = nil; S.pageTask = nil
    if task:isRunning() then pcall(function() task:terminate() end) end
    flog("w", "page capture timed out")
  end)
  if not task:start() then
    stopTimer("pageTimer"); S.pageTask = nil
    flog("w", "page capture could not start")
  end
end

-- Build the webhook JSON body. Returns body, attachedPP (or nil).
local function buildBody(text)
  local pp = ppPending()
  local payload = { text = text }
  if pp then payload.context = utf8Cap(pp.text, PP_MAX) end
  if S.page and S.page.url then
    payload.page_url = S.page.url
    payload.page_title = S.page.title or ""
    payload.page_app_frontmost = S.page.frontmost == true
  end
  return hs.json.encode(payload), pp, payload.context and #payload.context or 0
end

-- Only ever one of OUR alerts on screen; never touch other alerts, never re-show the same text.
local function closeAlerts()
  if S.alertId then hs.alert.closeSpecific(S.alertId, 0); S.alertId = nil end
  S.alertMsg = nil
end

local ALERT_STYLE = {
  textSize = 30,
  textColor = { white = 1, alpha = 1 },
  fillColor = { red = 0.03, green = 0.05, blue = 0.14, alpha = 0.96 },
  radius = 12,
  strokeColor = { red = 0.35, green = 0.55, blue = 1, alpha = 0.9 },
  strokeWidth = 2,
}

local function showAlert(msg, secs)
  if S.alertId and S.alertMsg == msg then return end   -- already showing: don't flash it
  closeAlerts()
  S.alertId = hs.alert.show(msg, secs or 2, ALERT_STYLE)
  S.alertMsg = msg
  -- forget the id after it expires so the same message can be shown again later
  local id = S.alertId
  hs.timer.doAfter((secs or 2) + 0.5, function() if S.alertId == id then S.alertId, S.alertMsg = nil, nil end end)
end

notify = function(msg, secs) showAlert(msg, secs or 2) end

local function killTask(t, name)
  if t and t:isRunning() then
    flog("w", "killing " .. name .. " pid " .. tostring(t:pid()))
    pcall(function() t:terminate() end)
    local pid = t:pid()
    hs.timer.doAfter(1, function()
      if t:isRunning() then os.execute("/bin/kill -9 " .. tostring(pid) .. " 2>/dev/null") end
    end)
  end
end

-- Return to idle from anywhere. Always safe to call.
local function reset(reason)
  S.gen = S.gen + 1          -- invalidates any pending callbacks
  stopAllTimers()
  killTask(S.recTask, "ffmpeg"); killTask(S.whisperTask, "whisper"); killTask(S.pageTask, "page capture")
  S.recTask, S.whisperTask, S.pageTask = nil, nil, nil
  S.page = nil
  if S.wavPath and not S.keepWav then os.remove(S.wavPath) end
  S.wavPath, S.keepWav = nil, nil
  if reason then flog("i", "reset: " .. reason) end
  setState("idle")
end

-- Wrap callbacks: any error => log, alert, reset to idle.
local function safe(name, fn)
  return function(...)
    local args = table.pack(...)
    local ok, err = xpcall(function() return fn(table.unpack(args, 1, args.n)) end, debug.traceback)
    if not ok then
      flog("e", name .. " error: " .. tostring(err))
      pcall(reset, "error in " .. name)
      pcall(notify, "⚠️ PointTalk error (see ~/.hammerspoon/voice_ptt.log)", 4)
    end
  end
end

-- Transcripts whisper tends to hallucinate on silence
local JUNK = { ["you"]=true, ["thank you"]=true, ["thanks for watching"]=true, ["bye"]=true, ["."]=true }

local function cleanTranscript(s)
  s = s or ""
  s = s:gsub("%b[]", ""):gsub("%b()", "")
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local key = s:lower():gsub("[%p]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if key == "" or JUNK[key] then return "" end
  return s
end

local function loadConfig()
  local ok, cfg = pcall(hs.json.read, CONFIG)
  if not ok or type(cfg) ~= "table" then return nil, "Can't read ~/.hammerspoon/voice-webhook.json" end
  local url, auth = cfg.url or "", cfg.authorization or ""
  if url == "" or auth == "" or url:find("PASTE_") or auth:find("PASTE_") or auth:find("YOUR_KEY") then
    return nil, "Fill in url + authorization in ~/.hammerspoon/voice-webhook.json"
  end
  return cfg
end

local function send(text, gen)
  local cfg, err = loadConfig()
  if not cfg then flog("w", "config not filled"); notify("⚠️ " .. err, 4); reset("no config"); return end
  setState("sending")
  showAlert("📤 Sending…", HTTP_MAX)
  S.httpTimer = hs.timer.doAfter(HTTP_MAX, safe("httpTimeout", function()
    if gen ~= S.gen then return end
    flog("e", "HTTP watchdog fired"); notify("⚠️ Webhook timed out", 4); reset("http timeout")
  end))
  local body, pp, ctxLen = buildBody(text)
  local headers = { ["Content-Type"] = "application/json", ["Authorization"] = cfg.authorization }
  flog("i", "POST webhook (" .. #body .. " bytes" .. (pp and (", PointTalk context " .. ctxLen .. " bytes") or "") .. ")")
  hs.http.asyncPost(cfg.url, body, headers, safe("httpCallback", function(status, respBody)
    if gen ~= S.gen then flog("w", "late HTTP callback ignored, status " .. tostring(status)); return end
    flog("i", "HTTP status " .. tostring(status))
    if status and status >= 200 and status < 300 then
      if pp then
        if S.pp == pp then ppClear("sent") end   -- mark used: never reattach to the next message
        notify("✅ Sent to Grok Bot (+ PointTalk)", 2)
      else
        notify("✅ Sent to Grok Bot", 2)
      end
    elseif status and status > 0 then
      notify("⚠️ Webhook HTTP " .. tostring(status), 4)
    else
      notify("⚠️ Webhook error (see log)", 4)
      flog("w", "POST error: " .. tostring(respBody))
    end
    reset("done")
  end))
end

local function fileSize(p)
  local f = p and io.open(p, "rb"); if not f then return 0 end
  local n = f:seek("end"); f:close(); return n or 0
end

local function transcribe(gen)
  if gen ~= S.gen or S.state == "processing" or S.state == "sending" then return end
  stopTimer("maxTimer"); stopTimer("killTimer"); stopTimer("killTimer2"); stopTimer("feedbackTimer")
  setState("processing")
  local size = fileSize(S.wavPath)
  flog("i", "wav size " .. size .. " bytes")
  if size < 2000 then
    notify("Didn't catch that (no audio — check Microphone permission)", 3); reset("no audio"); return
  end
  showAlert("⏳ Transcribing…", WHISPER_MAX)
  S.whisperTask = hs.task.new(WHISPER, safe("whisperExit", function(code, out, errOut)
    if gen ~= S.gen then return end
    stopTimer("whisperTimer"); S.whisperTask = nil
    if code ~= 0 then
      flog("e", "whisper exit " .. tostring(code) .. ": " .. tostring(errOut):sub(-500))
      notify("⚠️ whisper failed (exit " .. tostring(code) .. ")", 4); reset("whisper failed"); return
    end
    local text = cleanTranscript(out)
    flog("i", "transcript: " .. #text .. " bytes")   -- length only; the text itself is never logged
    if text == "" then notify("Didn't catch that", 2); reset("empty transcript"); return end
    send(text, gen)
  end), { "-m", MODEL, "-f", S.wavPath, "-nt", "-np", "-l", "en" })
  if not S.whisperTask or not S.whisperTask:start() then
    notify("⚠️ Couldn't start whisper-cli", 4); reset("whisper start failed"); return
  end
  flog("i", "whisper started")
  S.whisperTimer = hs.timer.doAfter(WHISPER_MAX, safe("whisperWatchdog", function()
    if gen ~= S.gen then return end
    flog("e", "whisper watchdog fired"); notify("⚠️ Transcription timed out", 4); reset("whisper timeout")
  end))
end

local function stopRecording(why)
  if S.state ~= "recording" then return end
  local gen = S.gen
  stopTimer("maxTimer"); stopTimer("feedbackTimer")
  local held = hs.timer.secondsSinceEpoch() - (S.pressedAt or 0)
  flog("i", string.format("stop (%s) after %.2fs", why, held))
  if held < MIN_HOLD then closeAlerts(); reset("too short"); return end
  setState("stopping")
  local t = S.recTask
  if not (t and t:isRunning()) then transcribe(gen); return end
  t:interrupt()   -- SIGINT: ffmpeg finalizes the wav header and exits
  S.killTimer = hs.timer.doAfter(FFMPEG_GRACE, safe("ffmpegGrace", function()
    if gen ~= S.gen or S.state ~= "stopping" then return end
    if t:isRunning() then
      flog("w", "ffmpeg still running " .. FFMPEG_GRACE .. "s after SIGINT; terminating")
      t:terminate()
      S.killTimer2 = hs.timer.doAfter(1, safe("ffmpegKill", function()
        if gen ~= S.gen or S.state ~= "stopping" then return end
        if t:isRunning() then flog("w", "SIGKILL ffmpeg"); os.execute("/bin/kill -9 " .. tostring(t:pid()) .. " 2>/dev/null") end
        transcribe(gen)
      end))
    else
      transcribe(gen)
    end
  end))
end

local function onPress()
  if S.state ~= "idle" then flog("w", "press ignored (busy)"); return end
  reset()                           -- clean slate, bumps gen
  local gen = S.gen
  -- Start this immediately on press, before recording can finish; async and 2s bounded.
  local pageOK, pageErr = pcall(capturePage, gen)
  if not pageOK then flog("w", "page capture unavailable") end
  setState("recording")
  S.pressedAt = hs.timer.secondsSinceEpoch()
  flog("i", "press: start recording")
  S.wavPath = (os.getenv("TMPDIR") or "/tmp/"):gsub("/?$", "/") .. "voice_ptt_" .. tostring(math.floor(S.pressedAt * 1000)) .. ".wav"
  -- ffmpeg starts immediately (no lost audio); pill + media pause wait a moment so quick
  -- Option taps / Option+letter never flash anything or pause music.
  S.feedbackTimer = hs.timer.doAfter(FEEDBACK_DELAY, safe("feedback", function()
    S.feedbackTimer = nil
    if gen ~= S.gen or S.state ~= "recording" then return end
    local p = hs.task.new(NOWPLAYING, nil, { "pause" }); S.npTask = p; if p then p:start() end
    local listening = ppPending() and "🎙 Listening + 📎 PointTalk" or "🎙 Listening…"
    showAlert(listening .. " (release Right ⌥ to send)", MAX_REC + 2)
  end))

  S.maxTimer = hs.timer.doAfter(MAX_REC, safe("maxRec", function()
    if gen == S.gen then flog("w", "max recording time reached"); stopRecording("max " .. MAX_REC .. "s") end
  end))

  S.recTask = hs.task.new(FFMPEG, safe("ffmpegExit", function(code, out, errOut)
    if gen ~= S.gen then return end
    flog("i", "ffmpeg exit " .. tostring(code))
    if S.state == "stopping" then
      transcribe(gen)
    elseif S.state == "recording" then
      flog("e", "ffmpeg died while recording: " .. tostring(errOut):sub(-500))
      notify("⚠️ Recording stopped unexpectedly", 3); reset("ffmpeg died")
    end
  end), { "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
          "-f", "avfoundation", "-i", ":default",
          "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", S.wavPath })
  if not S.recTask or not S.recTask:start() then
    notify("⚠️ Couldn't start ffmpeg", 3); reset("ffmpeg start failed"); return
  end
  flog("i", "ffmpeg pid " .. tostring(S.recTask:pid()))
end

local function onRelease() stopRecording("right option released") end

local function onCancel(why)
  if S.state ~= "recording" then return end
  flog("i", "cancel: " .. why)
  closeAlerts(); reset("cancelled")
end

function M.forceReset()
  flog("w", "force reset requested")
  if M._P then M._P.cancelled = M._P.holding end  -- ignore the release of any in-progress hold
  reset("force"); showAlert("🎙 PointTalk reset", 1)
end

M.press   = safe("press", onPress)
M.release = safe("release", onRelease)
M.cancel  = safe("cancel", onCancel)
M.state   = function() return S.state end
-- test hooks (no network): M._pp.isPointTalk(s), M._pp.onClipboard(s, at), M._pp.buildBody(text), M._pp.pending(), M._pp.clear()
M._pp = { isPointTalk = isPointTalk, onClipboard = ppOnClipboard, buildBody = buildBody,
          pending = ppPending, clear = ppClear, cap = utf8Cap }

-- _test(secs): press, wait secs, release. _testFile(path): run transcribe->send on an existing wav copy.
function M._test(secs)
  M.press()
  S.testTimer = hs.timer.doAfter(secs or 3, function() M.release() end)
  return "test started (" .. tostring(secs or 3) .. "s)"
end
function M._testFile(path)
  if S.state ~= "idle" then return "busy: " .. S.state end
  reset(); local gen = S.gen
  S.wavPath = path; S.pressedAt = hs.timer.secondsSinceEpoch() - 5
  setState("stopping"); flog("i", "_testFile " .. path)
  safe("testFile", function() transcribe(gen) end)()
  return "testFile started"
end

-- ---------------------------------------------------------------------------
-- Right-Option push-to-talk eventtap (module level so it is never GC'd)
-- ---------------------------------------------------------------------------
local ET = hs.eventtap.event.types
local P = { holding = false, cancelled = false }   -- physical hold tracking
M._P = P

local function otherMods(f)
  return f.cmd or f.ctrl or f.shift or f.fn
end

local function defer(name, fn) hs.timer.doAfter(0, safe(name, fn)) end

local function tapHandler(e)
  local ok, err = pcall(function()
    local t = e:getType()
    if t == ET.flagsChanged then
      local kc, f = e:getKeyCode(), e:getFlags()
      if kc == RALT_KEYCODE then
        local down = (e:rawFlags() & RALT_MASK) ~= 0
        if down and not P.holding then
          P.holding = true
          if not f.alt or otherMods(f) then
            P.cancelled = true
            defer("pttLog", function() flog("i", "event: right-option DOWN ignored (other modifiers held)") end)
          else
            P.cancelled = false
            defer("pttPress", function() flog("i", "event: right-option DOWN -> press"); M.press() end)
          end
        elseif not down and P.holding then
          P.holding = false
          local wasCancelled = P.cancelled; P.cancelled = false
          defer("pttRelease", function()
            flog("i", "event: right-option UP -> " .. (wasCancelled and "ignored (hold was cancelled)" or "release"))
            if not wasCancelled then M.release() end
          end)
        end
      elseif P.holding and not P.cancelled then
        P.cancelled = true
        defer("pttCancel", function() flog("i", "event: other modifier during hold"); M.cancel("other modifier during hold") end)
      end
    elseif P.holding and not P.cancelled then   -- keyDown / mouse down during hold
      P.cancelled = true
      local what = (t == ET.keyDown) and "key pressed during hold" or "mouse click during hold"
      defer("pttCancel", function() flog("i", "event: " .. what); M.cancel(what) end)
    end
  end)
  if not ok then pcall(flog, "e", "tap error: " .. tostring(err)) end
  return false   -- never swallow events
end

if M.pttTap then M.pttTap:stop() end
if M.tapWatch then M.tapWatch:stop() end
M.pttTap = hs.eventtap.new({ ET.flagsChanged, ET.keyDown, ET.leftMouseDown, ET.rightMouseDown, ET.otherMouseDown }, tapHandler)
M.pttTap:start()

-- macOS disables taps that time out / after secure input etc. Re-enable them.
M.tapWatch = hs.timer.doEvery(TAP_CHECK, function()
  local ok, err = pcall(function()
    if not M.pttTap then return end
    if not M.pttTap:isEnabled() then
      flog("w", "eventtap was disabled; restarting")
      P.holding, P.cancelled = false, false
      M.pttTap:stop(); M.pttTap:start()
      flog("w", "eventtap restarted, enabled=" .. tostring(M.pttTap:isEnabled()))
    end
  end)
  if not ok then pcall(flog, "e", "tapWatch error: " .. tostring(err)) end
end)

-- Clipboard watcher: only PointTalk-format text is retained (see ppOnClipboard).
if M.pbWatcher then M.pbWatcher:stop() end
M.pbWatcher = hs.pasteboard.watcher.new(function(content)
  local ok, err = pcall(ppOnClipboard, content)
  if not ok then pcall(flog, "e", "pasteboard watcher error: " .. tostring(err)) end
end)
M.pbWatcher:start()

if M.escHotkey then M.escHotkey:delete() end
M.escHotkey = hs.hotkey.bind(MODS, "escape", nil, safe("forceReset", M.forceReset))
M.menubar = hs.menubar.new()
if M.menubar then
  M.menubar:setTitle("🎙")
  M.menubar:setMenu(function()
    local pp = ppPending()
    local items = {
      { title = "PointTalk: " .. S.state, disabled = true },
    }
    if pp then
      local age = math.floor(hs.timer.secondsSinceEpoch() - pp.at)
      table.insert(items, { title = string.format("📎 PointTalk pending (%.1f KB, %ds ago) — attaches to next message",
        math.min(#pp.text, PP_MAX) / 1024, age), disabled = true })
      table.insert(items, { title = "Discard PointTalk capture", fn = function() ppClear("discarded") end })
    end
    for _, it in ipairs({
      { title = "Force reset (⌃⌥⌘⎋)", fn = M.forceReset },
      { title = "Open log", fn = function() hs.execute("open -a Console " .. LOGFILE) end },
    }) do table.insert(items, it) end
    return items
  end)
end

closeAlerts()
flog("i", "voice_ptt loaded: hold Right Option to talk; ctrl+alt+cmd+Escape resets; tap enabled=" .. tostring(M.pttTap:isEnabled()))
return M
