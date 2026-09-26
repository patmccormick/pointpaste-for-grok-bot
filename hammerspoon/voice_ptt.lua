-- PointTalk: hold-to-talk -> whisper.cpp (on-device) -> Grok Bot webhook
-- Install as ~/.hammerspoon/voice_ptt.lua and add  require("voice_ptt")  to ~/.hammerspoon/init.lua
-- Trigger: hold RIGHT Option alone (keycode 61) to talk, release to send.
--          Any other key/modifier/mouse click during the hold cancels that hold (so Option+letter still types).
-- Add more: press Right Option again while a message is still transcribing or in the short
--          "Sending in 1s" window; the extra speech is appended to the SAME message.
--          Once the POST has started, a new press starts a new, separate message.
-- Voice replies: menubar toggle (persisted), or start/end a message with "voice reply" / "reply by voice".
-- Escape hatch: ctrl+alt+cmd+Escape (force reset) or the menubar icon.
--
-- States: idle -> recording -> transcribing -> grace (1.5 s) -> sending -> idle
--   recording    : Right Option held (ffmpeg capturing this part)
--   transcribing : released; ffmpeg finalizing and/or whisper running.  Re-press => record another part
--   grace        : all parts transcribed; POST fires after GRACE seconds.  Re-press => record another part
--   sending      : POST in flight (can't be cancelled).                   Re-press => new separate message
local M = {}

-- ---- Install-specific names ---------------------------------------------------
local LOG_TAG      = "voice_ptt"             -- logger name, log file, temp wav prefix
local CONFIG_NAME  = "voice-webhook.json"    -- in ~/.hammerspoon: { "url": ..., "authorization": "Bearer ..." }
local DEST_LABEL   = "Grok Bot"              -- "✅ Sent to ..."
local PP_LABEL     = "PointTalk"             -- name shown for element-pack captures
local MENU_LABEL   = "PointTalk"             -- first line of the menubar menu
local ERROR_LABEL  = "PointTalk error"
local RESET_LABEL  = "PointTalk reset"
local LOG_TRANSCRIPTS     = false            -- false: log only transcript length
local VOICE_REPLY_KEY     = "pointtalk.voice_reply"   -- hs.settings key
local VOICE_REPLY_DEFAULT = false
-- The PointTalk extension ("Copy for Grok Bot", extension/ in this kit) copies markdown
-- starting with this header (see packMarkdown() in extension/pick-mode.js).
local PP_HEADER    = "### Element pack"

local HOME        = os.getenv("HOME")
local FFMPEG      = (hs.fs.attributes("/opt/homebrew/bin/ffmpeg") and "/opt/homebrew/bin/ffmpeg") or "/usr/local/bin/ffmpeg"
local WHISPER     = HOME .. "/.hammerspoon/local/bin/whisper-cli"
local NOWPLAYING  = HOME .. "/.hammerspoon/local/bin/nowplaying-cli"
local MODEL       = HOME .. "/.hammerspoon/models/ggml-base.en.bin"
local CONFIG      = HOME .. "/.hammerspoon/" .. CONFIG_NAME
local LOGFILE     = HOME .. "/.hammerspoon/" .. LOG_TAG .. ".log"
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
local MAX_REC     = 60    -- s; auto-stop (per part)
local FFMPEG_GRACE= 3     -- s after SIGINT before terminate/kill
local WHISPER_MAX = 60    -- s watchdog (per part)
local HTTP_MAX    = 20    -- s watchdog
local GRACE       = 1.5   -- s between "all parts transcribed" and POST; re-press merges
local MEDIA_QUERY_MAX = 2 -- s; nowplaying-cli query timeout
local PP_WINDOW   = 300   -- s; a capture this recent is attached to the next voice message
local PP_MAX      = 20000 -- bytes; cap for the "context" field
local VOICE_REPLY_LINE = "\n\n(Reply as a voice memo.)"
local ADDED_SEP   = "\n\nAdded: "

local log = hs.logger.new(LOG_TAG, "info")

-- Module-level state (keeps hs.task / timers / taps referenced => not GC'd)
-- S.msg        : message being composed, not yet POSTed:
--                { id, segs = { seg... }, page = {url,title,frontmost}, voiceAsked = bool, sent = bool }
--   seg        : { n, wav, pressedAt, status = recording|stopping|queued|transcribing|done, text, task }
-- S.rec        : the seg currently recording (nil if none)
-- S.sendingMsg : message whose POST is in flight (detached from S.msg)
-- S.mediaPaused: true only if WE paused media (so we only resume what we paused)
-- S.pp         : { text, at } last element-pack clipboard copy (never logged); nil once sent/expired
local S = { state = "idle", nextId = 0 }
local notify
M._S = S

local function flog(level, msg)
  msg = tostring(msg)
  if level == "e" then log.e(msg) elseif level == "w" then log.w(msg) else log.i(msg) end
  local f = io.open(LOGFILE, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), " [", level, "] [", S.state, "] ", msg, "\n"); f:close() end
end

local function now() return hs.timer.secondsSinceEpoch() end
local function stopTimer(name) if S[name] then S[name]:stop(); S[name] = nil end end
local function stopAllTimers()
  for _, n in ipairs({ "maxTimer", "feedbackTimer", "graceTimer", "whisperTimer", "pageTimer", "mediaTimer" }) do stopTimer(n) end
end

-- ---------------------------------------------------------------------------
-- Element-pack capture tracking. Only clipboard text in that format is ever kept;
-- anything else (passwords etc.) is never stored, logged, or sent.
-- ---------------------------------------------------------------------------
local function isPointPaste(s)
  if type(s) ~= "string" or #s < #PP_HEADER then return false end
  local body = s:gsub("^%s+", "")
  if body:sub(1, #PP_HEADER) ~= PP_HEADER then return false end
  -- required structure lines produced by packMarkdown()
  return body:find("\n%*%*Page:%*%* ") ~= nil and body:find("\n%*%*Target:%*%* ") ~= nil
end

local function ppPending()
  local pp = S.pp
  if pp and (now() - pp.at) <= PP_WINDOW then return pp end
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

-- ---------------------------------------------------------------------------
-- Voice-reply setting (persisted with hs.settings) and per-message phrases
-- ---------------------------------------------------------------------------
local function voiceReplyEnabled()
  local v = hs.settings.get(VOICE_REPLY_KEY)
  if v == nil then return VOICE_REPLY_DEFAULT end
  return v == true
end
local function setVoiceReply(on) hs.settings.set(VOICE_REPLY_KEY, on and true or false) end

-- Case-insensitive; whole words only ("invoice reply" doesn't match).
local VR_START = { "^[%s%p]*voice[%s%p]+reply%f[%A][%s%p]*", "^[%s%p]*reply[%s%p]+by[%s%p]+voice%f[%A][%s%p]*" }
local VR_END   = { "[%s%p]*%f[%a]voice[%s%p]+reply[%s%p]*$", "[%s%p]*%f[%a]reply[%s%p]+by[%s%p]+voice[%s%p]*$" }
-- Returns text without a leading/trailing voice-reply phrase, and whether one was found.
local function stripVoiceReply(s)
  local found = false
  for _, pat in ipairs(VR_START) do
    local _, b = s:lower():find(pat)
    if b then s = s:sub(b + 1); found = true; break end
  end
  for _, pat in ipairs(VR_END) do
    local a = s:lower():find(pat)
    if a then
      local keep = s:sub(a):match("^[%.!?]") or ""   -- keep the previous sentence's full stop
      s = s:sub(1, a - 1) .. keep; found = true; break
    end
  end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s:match("^[%.!?,;:]+$") then s = "" end
  return s, found
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
local ICONS = { idle = "🎙", recording = "🔴", transcribing = "⏳", grace = "⏱", sending = "📤" }
local function refreshTitle()
  if not M.menubar then return end
  M.menubar:setTitle((ICONS[S.state] or "🎙") .. (ppPending() and "📎" or ""))
end

local function setState(st)
  if S.state ~= st then flog("i", "state -> " .. st) end
  S.state = st
  refreshTitle()
end

-- The state is derived from facts, so it can never disagree with what is actually running.
local function updateState()
  local st = "idle"
  if S.msg then
    if S.rec then st = "recording"
    elseif S.graceTimer then st = "grace"
    else st = "transcribing" end
  elseif S.sendingMsg then
    st = "sending"
  end
  setState(st)
end

local function ppClear(why)
  if S.ppExpiry then S.ppExpiry:stop(); S.ppExpiry = nil end
  if S.pp then flog("i", PP_LABEL .. " capture cleared (" .. why .. ")") end
  S.pp = nil
  refreshTitle()
end

-- Called with new clipboard text (watcher). Other content is ignored and not retained.
local function ppOnClipboard(content, at)
  if not isPointPaste(content) then return false end
  if S.ppExpiry then S.ppExpiry:stop(); S.ppExpiry = nil end
  S.pp = { text = content, at = at or now() }
  flog("i", PP_LABEL .. " capture copied (" .. #content .. " bytes)")
  S.ppExpiry = hs.timer.doAfter(PP_WINDOW + 1, function()
    pcall(function() S.ppExpiry = nil; if S.pp and not ppPending() then ppClear("expired"); notify("📎 " .. PP_LABEL .. " capture expired", 2) end end)
  end)
  refreshTitle()
  notify("📎 " .. PP_LABEL .. " ready — hold right Option to talk", 3)
  return true
end

local function pageHost(url)
  local host = tostring(url):match("^[%a][%w+.-]*://([^/%?#]+)") or ""
  host = host:gsub("^.-@", ""):gsub(":%d+$", "")
  return host
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

-- ---------------------------------------------------------------------------
-- Media: pause only if something is playing; resume only what we paused,
-- and only once the whole message is finished (sent or cancelled).
-- ---------------------------------------------------------------------------
local function pauseMedia()
  if S.mediaPaused or S.mediaQuery then return end
  local t
  t = hs.task.new(NOWPLAYING, function(code, out)
    if S.mediaQuery ~= t then return end
    S.mediaQuery = nil; stopTimer("mediaTimer")
    local rate = tonumber(tostring(out):match("[%d%.]+"))
    if code ~= 0 or not rate or rate <= 0 then return end
    if not S.msg or S.mediaPaused then return end         -- message already over
    local p = hs.task.new(NOWPLAYING, nil, { "pause" })
    if p and p:start() then S.npTask = p; S.mediaPaused = true; flog("i", "media paused") end
  end, { "get", "playbackRate" })
  if not (t and t:start()) then return end
  S.mediaQuery = t
  S.mediaTimer = hs.timer.doAfter(MEDIA_QUERY_MAX, function()
    S.mediaTimer = nil
    if S.mediaQuery == t then S.mediaQuery = nil; pcall(function() t:terminate() end) end
  end)
end

local function resumeMedia()
  if not S.mediaPaused then return end
  S.mediaPaused = false
  local p = hs.task.new(NOWPLAYING, nil, { "play" }); S.npTask = p; if p then p:start() end
  flog("i", "media resumed")
end

local function maybeResume()
  if not S.msg and not S.sendingMsg and not S.rec then resumeMedia() end
end

-- ---------------------------------------------------------------------------
-- Page capture (Brave active tab) at the first press of a message, never delaying recording.
-- Only the host is logged; URL/title are retained solely for that message's body.
-- ---------------------------------------------------------------------------
local function capturePage(msg)
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
    if code ~= 0 then
      local e = tostring(errOut):lower()
      if e:find("not authorized", 1, true) or e:find("not permitted", 1, true) or e:find("automation", 1, true) or e:find("-1743", 1, true) then
        flog("w", "page capture permission error")
      else
        flog("w", "page capture failed")
      end
      return
    end
    if msg.sent then return end
    local url, title = tostring(out):match("^(.-)\1(.*)")
    if not url then flog("w", "page capture returned no tab data"); return end
    url = url:gsub("[\r\n]+$", "")
    title = title:gsub("[\r\n]+$", "")
    if url == "" then flog("w", "page capture returned no URL"); return end
    msg.page = { url = url, title = utf8Cap(title, 300), frontmost = frontmost }
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

-- Build the webhook JSON body. Returns body, attachedPP (or nil), context length.
local function buildBody(msg, voice)
  local pp = ppPending()
  local text = msg.text or ""
  if voice then text = text .. VOICE_REPLY_LINE end
  local payload = { text = text }
  if voice then payload.reply_as = "voice_memo" end
  if pp then payload.context = utf8Cap(pp.text, PP_MAX) end
  if msg.page and msg.page.url then
    payload.page_url = msg.page.url
    payload.page_title = msg.page.title or ""
    payload.page_app_frontmost = msg.page.frontmost == true
  end
  return hs.json.encode(payload), pp, payload.context and #payload.context or 0
end

-- ---------------------------------------------------------------------------
-- Message lifecycle
-- ---------------------------------------------------------------------------
local function discardSeg(seg)
  for _, k in ipairs({ "killTimer", "killTimer2" }) do if seg[k] then seg[k]:stop(); seg[k] = nil end end
  killTask(seg.task, "ffmpeg")
  if seg.wav and not seg.keep then os.remove(seg.wav) end
  seg.status = "discarded"
end

-- Drop the message being composed (not an in-flight POST) and return to idle. Always safe to call.
local function reset(reason)
  stopAllTimers()
  killTask(S.pageTask, "page capture"); S.pageTask = nil
  killTask(S.whisperTask, "whisper"); S.whisperTask = nil
  if S.mediaQuery then pcall(function() S.mediaQuery:terminate() end); S.mediaQuery = nil end
  if S.msg then for _, seg in ipairs(S.msg.segs) do discardSeg(seg) end end
  S.msg, S.rec = nil, nil
  if reason then flog("i", "reset: " .. reason) end
  updateState()
  maybeResume()
end

-- Wrap callbacks: any error => log, alert, reset to idle.
local function safe(name, fn)
  return function(...)
    local args = table.pack(...)
    local ok, err = xpcall(function() return fn(table.unpack(args, 1, args.n)) end, debug.traceback)
    if not ok then
      flog("e", name .. " error: " .. tostring(err))
      pcall(reset, "error in " .. name)
      pcall(notify, "⚠️ " .. ERROR_LABEL .. " (see ~/.hammerspoon/" .. LOG_TAG .. ".log)", 4)
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
  if not ok or type(cfg) ~= "table" then return nil, "Can't read ~/.hammerspoon/" .. CONFIG_NAME end
  local url, auth = cfg.url or "", cfg.authorization or ""
  if url == "" or auth == "" or url:find("PASTE_") or auth:find("PASTE_") or auth:find("YOUR_KEY") then
    return nil, "Fill in url + authorization in ~/.hammerspoon/" .. CONFIG_NAME
  end
  return cfg
end

local function fileSize(p)
  local f = p and io.open(p, "rb"); if not f then return 0 end
  local n = f:seek("end"); f:close(); return n or 0
end

local pump   -- forward declaration

-- POST the message once. After this, S.msg is cleared so a new press starts a new message.
local function send(msg)
  if msg.sent then flog("w", "duplicate send blocked (msg " .. msg.id .. ")"); return end
  local cfg, err = loadConfig()
  if not cfg then flog("w", "config not filled"); notify("⚠️ " .. err, 4); reset("no config"); return end
  msg.sent = true
  if S.msg == msg then S.msg = nil end
  S.sendingMsg = msg
  updateState()
  showAlert("📤 Sending…", HTTP_MAX)
  local voice = voiceReplyEnabled() or msg.voiceAsked == true
  local body, pp, ctxLen = buildBody(msg, voice)
  local function finish()
    if msg.httpTimer then msg.httpTimer:stop(); msg.httpTimer = nil end
    if S.sendingMsg == msg then S.sendingMsg = nil end
    updateState()
    maybeResume()
  end
  msg.httpTimer = hs.timer.doAfter(HTTP_MAX, safe("httpTimeout", function()
    msg.httpTimer = nil
    if msg.done then return end
    msg.done = true
    flog("e", "HTTP watchdog fired (msg " .. msg.id .. ")")
    if not msg.abandoned then notify("⚠️ Webhook timed out", 4) end
    finish()
  end))
  local headers = { ["Content-Type"] = "application/json", ["Authorization"] = cfg.authorization }
  flog("i", "POST webhook (msg " .. msg.id .. ", " .. #msg.segs .. " part(s), " .. #body .. " bytes"
    .. (voice and ", voice reply" or "") .. (pp and (", " .. PP_LABEL .. " context " .. ctxLen .. " bytes") or "") .. ")")
  hs.http.asyncPost(cfg.url, body, headers, safe("httpCallback", function(status, respBody)
    if msg.done then flog("w", "late HTTP callback ignored, status " .. tostring(status)); return end
    msg.done = true
    flog("i", "HTTP status " .. tostring(status) .. " (msg " .. msg.id .. ")")
    if msg.abandoned then finish(); return end
    if status and status >= 200 and status < 300 then
      if pp and S.pp == pp then ppClear("sent") end   -- mark used: never reattach to the next message
      local label = "✅ Sent to " .. DEST_LABEL .. (pp and (" (+ " .. PP_LABEL .. ")") or "") .. (voice and " 🔊" or "")
      if not S.rec then notify(label, 2) end           -- don't cover the pill of a new recording
    elseif status and status > 0 then
      notify("⚠️ Webhook HTTP " .. tostring(status), 4)
    else
      notify("⚠️ Webhook error (see log)", 4)
      flog("w", "POST error: " .. tostring(respBody))
    end
    finish()
  end))
end

-- All parts transcribed: combine, then wait GRACE seconds (re-press merges) before POST.
local function startGrace(msg)
  local parts, noAudio = {}, false
  for _, seg in ipairs(msg.segs) do
    if seg.text and seg.text ~= "" then parts[#parts + 1] = seg.text end
    if seg.noAudio then noAudio = true end
  end
  if #parts == 0 then
    notify(noAudio and "Didn't catch that (no audio — check Microphone permission)" or "Didn't catch that", 3)
    reset("empty transcript"); return
  end
  msg.text = table.concat(parts, ADDED_SEP)
  stopTimer("graceTimer")
  S.graceTimer = hs.timer.doAfter(GRACE, safe("grace", function()
    S.graceTimer = nil
    if S.msg ~= msg or S.rec or msg.sent then updateState(); return end
    send(msg)
  end))
  updateState()
  closeAlerts()
  showAlert("Sending in 1s — hold Right Option to add more", GRACE + 0.5)
end

local function onTranscript(msg, seg, raw)
  local text = cleanTranscript(raw)
  local stripped, asked = stripVoiceReply(text)
  if asked then msg.voiceAsked = true; flog("i", "voice reply requested by phrase (part " .. seg.n .. ")") end
  seg.text = stripped
  if LOG_TRANSCRIPTS then flog("i", "transcript (part " .. seg.n .. "): " .. seg.text)
  else flog("i", "transcript (part " .. seg.n .. "): " .. #seg.text .. " bytes") end
end

-- Start whisper on one part. Returns true if async work started (or the message was reset),
-- false if the part was resolved immediately (no audio).
local function transcribeSeg(msg, seg)
  seg.status = "transcribing"
  local size = fileSize(seg.wav)
  flog("i", "part " .. seg.n .. " wav size " .. size .. " bytes")
  if size < 2000 then
    seg.status, seg.text, seg.noAudio = "done", "", true
    if not seg.keep then os.remove(seg.wav) end
    return false
  end
  local t
  t = hs.task.new(WHISPER, safe("whisperExit", function(code, out, errOut)
    if S.whisperTask ~= t then return end
    S.whisperTask = nil; stopTimer("whisperTimer")
    if not seg.keep then os.remove(seg.wav) end
    if S.msg ~= msg then return end
    if code ~= 0 then
      flog("e", "whisper exit " .. tostring(code) .. ": " .. tostring(errOut):sub(-500))
      notify("⚠️ whisper failed (exit " .. tostring(code) .. ")", 4); reset("whisper failed"); return
    end
    onTranscript(msg, seg, out)
    seg.status = "done"
    pump()
  end), { "-m", MODEL, "-f", seg.wav, "-nt", "-np", "-l", "en" })
  S.whisperTask = t
  if not t or not t:start() then
    S.whisperTask = nil
    notify("⚠️ Couldn't start whisper-cli", 4); reset("whisper start failed"); return true
  end
  flog("i", "whisper started (part " .. seg.n .. ")")
  S.whisperTimer = hs.timer.doAfter(WHISPER_MAX, safe("whisperWatchdog", function()
    if S.whisperTask ~= t then return end
    flog("e", "whisper watchdog fired"); notify("⚠️ Transcription timed out", 4); reset("whisper timeout")
  end))
  return true
end

-- Advance the pipeline: one whisper at a time, in order; grace once every part is done.
pump = function()
  local msg = S.msg
  if not msg then updateState(); return end
  if S.whisperTask then updateState(); return end
  for _, seg in ipairs(msg.segs) do
    if seg.status == "queued" then
      if transcribeSeg(msg, seg) then updateState(); return end
    end
  end
  for _, seg in ipairs(msg.segs) do
    if seg.status ~= "done" then updateState(); return end   -- still recording / finalizing
  end
  startGrace(msg)
end

-- Throw away the part being recorded (cancelled / too short / ffmpeg died). Earlier parts continue.
local function dropRecording(why)
  local seg = S.rec
  if not seg then return end
  stopTimer("maxTimer"); stopTimer("feedbackTimer")
  S.rec = nil
  discardSeg(seg)
  local msg = S.msg
  if msg then
    for i, s in ipairs(msg.segs) do if s == seg then table.remove(msg.segs, i); break end end
  end
  flog("i", "part " .. seg.n .. " discarded (" .. why .. ")")
  if not msg or #msg.segs == 0 then closeAlerts(); reset(why); return end
  pump()
end

local function stopRecording(why)
  local seg = S.rec
  if not seg then return end
  stopTimer("maxTimer"); stopTimer("feedbackTimer")
  local held = now() - seg.pressedAt
  flog("i", string.format("stop part %d (%s) after %.2fs", seg.n, why, held))
  if held < MIN_HOLD then dropRecording("too short"); return end
  S.rec = nil
  seg.status = "stopping"
  updateState()
  showAlert("⏳ Transcribing… (hold Right ⌥ to add more)", WHISPER_MAX)
  local t = seg.task
  if not (t and t:isRunning()) then seg.status = "queued"; pump(); return end
  t:interrupt()   -- SIGINT: ffmpeg finalizes the wav header and exits (exit callback queues it)
  seg.killTimer = hs.timer.doAfter(FFMPEG_GRACE, safe("ffmpegGrace", function()
    seg.killTimer = nil
    if seg.status ~= "stopping" then return end
    if t:isRunning() then
      flog("w", "ffmpeg still running " .. FFMPEG_GRACE .. "s after SIGINT; terminating")
      t:terminate()
      seg.killTimer2 = hs.timer.doAfter(1, safe("ffmpegKill", function()
        seg.killTimer2 = nil
        if seg.status ~= "stopping" then return end
        if t:isRunning() then flog("w", "SIGKILL ffmpeg"); os.execute("/bin/kill -9 " .. tostring(t:pid()) .. " 2>/dev/null") end
        seg.status = "queued"; pump()
      end))
    else
      seg.status = "queued"; pump()
    end
  end))
end

-- Record one part of S.msg.
local function startSegment()
  local msg = S.msg
  local t0 = now()
  local n = #msg.segs + 1
  local seg = { n = n, status = "recording", pressedAt = t0,
    wav = (os.getenv("TMPDIR") or "/tmp/"):gsub("/?$", "/") .. LOG_TAG .. "_" .. msg.id .. "_" .. n .. "_" .. tostring(math.floor(t0 * 1000)) .. ".wav" }
  table.insert(msg.segs, seg)
  S.rec = seg
  updateState()
  -- ffmpeg starts immediately (no lost audio); pill + media pause wait a moment so quick
  -- Option taps / Option+letter never flash anything or pause music.
  S.feedbackTimer = hs.timer.doAfter(FEEDBACK_DELAY, safe("feedback", function()
    S.feedbackTimer = nil
    if S.rec ~= seg then return end
    pauseMedia()
    local label
    if n > 1 then label = "🎙 Adding more (part " .. n .. ")…"
    elseif ppPending() then label = "🎙 Listening + 📎 " .. PP_LABEL
    else label = "🎙 Listening…" end
    showAlert(label .. " (release Right ⌥ to send)", MAX_REC + 2)
  end))
  S.maxTimer = hs.timer.doAfter(MAX_REC, safe("maxRec", function()
    if S.rec == seg then flog("w", "max recording time reached"); stopRecording("max " .. MAX_REC .. "s") end
  end))
  seg.task = hs.task.new(FFMPEG, safe("ffmpegExit", function(code, out, errOut)
    flog("i", "ffmpeg exit " .. tostring(code) .. " (part " .. n .. ")")
    if seg.status == "stopping" then
      if seg.killTimer then seg.killTimer:stop(); seg.killTimer = nil end
      seg.status = "queued"; pump()
    elseif seg.status == "recording" and S.rec == seg then
      flog("e", "ffmpeg died while recording: " .. tostring(errOut):sub(-500))
      notify("⚠️ Recording stopped unexpectedly", 3); dropRecording("ffmpeg died")
    end
  end), { "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
          "-f", "avfoundation", "-i", ":default",
          "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", seg.wav })
  if not seg.task or not seg.task:start() then
    notify("⚠️ Couldn't start ffmpeg", 3); dropRecording("ffmpeg start failed"); return
  end
  flog("i", "ffmpeg pid " .. tostring(seg.task:pid()) .. " (msg " .. msg.id .. " part " .. n .. ")")
end

local function onPress()
  if S.rec then flog("w", "press ignored (already recording)"); return end
  local msg = S.msg
  if msg and not msg.sent then
    -- Still transcribing or in the grace window: cancel the pending send and add another part.
    stopTimer("graceTimer")
    flog("i", "press: add more to msg " .. msg.id .. " (part " .. (#msg.segs + 1) .. ")")
    startSegment()
    return
  end
  S.nextId = S.nextId + 1
  S.msg = { id = S.nextId, segs = {} }
  flog("i", "press: new msg " .. S.msg.id .. (S.sendingMsg and " (previous message still sending)" or ""))
  local pageOK = pcall(capturePage, S.msg)   -- async and 2 s bounded
  if not pageOK then flog("w", "page capture unavailable") end
  startSegment()
end

local function onRelease() stopRecording("right option released") end

local function onCancel(why)
  if not S.rec then return end
  flog("i", "cancel: " .. why)
  closeAlerts(); dropRecording("cancelled")
end

function M.forceReset()
  flog("w", "force reset requested")
  if M._P then M._P.cancelled = M._P.holding end  -- ignore the release of any in-progress hold
  if S.sendingMsg then S.sendingMsg.abandoned = true; S.sendingMsg = nil end
  reset("force"); showAlert("🎙 " .. RESET_LABEL, 1)
end

M.press   = safe("press", onPress)
M.release = safe("release", onRelease)
M.cancel  = safe("cancel", onCancel)
M.state   = function() return S.state end
M.voiceReply = { enabled = voiceReplyEnabled, set = setVoiceReply }
-- test hooks (no network): M._pp.isPointPaste(s), M._pp.onClipboard(s, at), M._pp.pending(), M._pp.clear(),
-- M._vr.strip(s) -> text, found
M._pp = { isPointPaste = isPointPaste, onClipboard = ppOnClipboard, buildBody = buildBody,
          pending = ppPending, clear = ppClear, cap = utf8Cap }
M._vr = { strip = stripVoiceReply }

-- _test(secs): press, wait secs, release. _testFile(path): transcribe->grace->send an existing wav (kept).
function M._test(secs)
  M.press()
  S.testTimer = hs.timer.doAfter(secs or 3, function() M.release() end)
  return "test started (" .. tostring(secs or 3) .. "s)"
end
function M._testFile(path)
  if S.msg or S.rec then return "busy: " .. S.state end
  S.nextId = S.nextId + 1
  S.msg = { id = S.nextId, segs = { { n = 1, status = "queued", wav = path, keep = true, pressedAt = now() } } }
  flog("i", "_testFile " .. path)
  safe("testFile", pump)()
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

-- Clipboard watcher: only element-pack text is retained (see ppOnClipboard).
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
      { title = MENU_LABEL .. ": " .. S.state, disabled = true },
      { title = "Voice replies (🔊 voice memo)", checked = voiceReplyEnabled(), fn = function()
          local on = not voiceReplyEnabled()
          setVoiceReply(on)
          flog("i", "voice replies " .. (on and "on" or "off"))
          notify(on and "🔊 Voice replies on" or "Voice replies off", 2)
        end },
    }
    if pp then
      local age = math.floor(now() - pp.at)
      table.insert(items, { title = string.format("📎 %s pending (%.1f KB, %ds ago) — attaches to next message",
        PP_LABEL, math.min(#pp.text, PP_MAX) / 1024, age), disabled = true })
      table.insert(items, { title = "Discard " .. PP_LABEL .. " capture", fn = function() ppClear("discarded") end })
    end
    for _, it in ipairs({
      { title = "Force reset (⌃⌥⌘⎋)", fn = M.forceReset },
      { title = "Open log", fn = function() hs.execute("open -a Console " .. LOGFILE) end },
    }) do table.insert(items, it) end
    return items
  end)
end

closeAlerts()
flog("i", LOG_TAG .. " loaded: hold Right Option to talk (re-press to add more); voice replies "
  .. (voiceReplyEnabled() and "on" or "off") .. "; ctrl+alt+cmd+Escape resets; tap enabled=" .. tostring(M.pttTap:isEnabled()))
return M
