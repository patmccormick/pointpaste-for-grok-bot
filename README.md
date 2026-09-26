# PointTalk

Point at anything on screen, hold a key, and talk to your Grok Bot agents.

Talk to Grok Bot from your Mac (or iPhone) and show it exactly what you're looking at.

- **Voice (Mac):** hold **Right Option**, speak, let go. Your speech is transcribed **on your Mac** (whisper.cpp) and the text is sent to your Grok Bot webhook, along with the URL and title of the Brave tab you were on.
- **PointTalk (browser extension):** press **Alt+Shift+G** (⌥⇧G), click any element on a page, add a note, and copy a compact "element pack" (page URL, CSS path, text, layout, trimmed HTML). Paste it into Grok Bot chat, or just start talking: a PointTalk copy made in the last 5 minutes is attached automatically to your next voice message.
- **Voice (iPhone):** an Apple Shortcut that dictates and sends the text to the same webhook.

## What's in here

| Folder | What it is |
|---|---|
| `extension/` | PointTalk Chromium extension (Brave, Chrome, Edge) |
| `hammerspoon/` | `voice_ptt.lua` (push-to-talk), `init.lua` snippet, `voice-webhook.example.json` |
| `install/install.sh` | Builds/downloads everything the voice part needs |

## Requirements

- Apple Silicon Mac, recent macOS
- [Hammerspoon](https://www.hammerspoon.org) (`brew install --cask hammerspoon`)
- [Homebrew](https://brew.sh) and Xcode Command Line Tools (`xcode-select --install`)
- Brave (page URL/title capture is Brave-only) or Chrome/Edge (extension only)
- ~200 MB disk (whisper model ~148 MB)
- A Grok Bot webhook routine (URL + key)

## Install

### 1. Browser extension

1. Keep the `extension/` folder somewhere permanent.
2. Open `brave://extensions` (or `chrome://extensions`), turn on **Developer mode**.
3. **Load unpacked** and pick the `extension/` folder.
4. Optional: `brave://extensions/shortcuts` to confirm/change **Alt+Shift+G**.

### 2. Voice push-to-talk

```bash
git clone https://github.com/patmccormick/pointpaste-for-grok-bot.git
cd pointpaste-for-grok-bot
./install/install.sh
```

The script (safe to re-run):

- installs `ffmpeg` (and `cmake` to build) with Homebrew if missing
- clones and builds `whisper-cli` from [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Metal, static) into `~/.hammerspoon/local/bin`
- downloads the `ggml-base.en` model from Hugging Face into `~/.hammerspoon/models`
- builds `nowplaying-cli` (used to pause music while you talk) into `~/.hammerspoon/local`, falling back to Homebrew
- copies `voice_ptt.lua` to `~/.hammerspoon/`, adds `require("voice_ptt")` to `init.lua`, and creates `voice-webhook.json` from the example **only if you don't already have one**

Then:

1. Edit `~/.hammerspoon/voice-webhook.json`:
   ```json
   { "url": "<your webhook URL>", "authorization": "Bearer <your key>" }
   ```
   Keep this file private (the installer sets it to `chmod 600`). Never commit it.
2. Open Hammerspoon, choose **Reload Config**, and grant these in **System Settings → Privacy & Security**:
   - **Accessibility** → Hammerspoon (needed to see the Right Option key)
   - **Microphone** → Hammerspoon (prompted on first recording)
   - **Automation** → Hammerspoon → **Brave Browser** (prompted on first use; lets it read the active tab's URL/title)
3. Look for 🎙 in the menu bar.

### Using it

- **Hold Right Option** (alone) to record; release to send. Taps shorter than 0.4 s are ignored; pressing any other key, modifier, or mouse button while holding cancels, so Option+letter still types normally. Max 60 s per message.
- Menu bar: 🎙 idle, 🔴 recording, ⏳ transcribing, 📤 sending, 📎 a PointTalk capture is waiting.
- Stuck? **Ctrl+Option+Cmd+Esc** force-resets, or use the menu bar icon. Log: `~/.hammerspoon/voice_ptt.log`.

What gets POSTed (JSON) to your webhook:

```json
{
  "text": "what you said",
  "page_url": "active Brave tab URL (if Brave is running)",
  "page_title": "tab title",
  "page_app_frontmost": true,
  "context": "PointTalk pack copied in the last 5 min (optional, max 20 KB)"
}
```

## Getting a webhook URL and key from Grok Bot

1. In Grok Bot, create a new **routine** and choose a **webhook** trigger.
2. Tell the routine what to do with incoming messages (e.g. "Treat `text` as a request from me; use `page_url`, `page_title`, and `context` when present").
3. Save it and copy the webhook **URL** and **key** it gives you.
4. Put them in `~/.hammerspoon/voice-webhook.json` as `url` and `authorization` (`"Bearer "` + key). Use the same values in the iPhone Shortcut.

## iPhone Shortcut (build it yourself)

Open the **Shortcuts** app → **+** → name it e.g. "Grok Bot".

1. Add **Dictate Text** (language English; *Stop Listening*: After Pause).
2. Add **Get Contents of URL**:
   - URL: your webhook URL
   - Method: **POST**
   - Headers: `Authorization` = `Bearer <your key>`; `Content-Type` = `application/json`
   - Request Body: **JSON**, add a Text field `text` = the **Dictated Text** variable
3. Optional: add **Show Notification** "Sent to Grok Bot".
4. Run it from the Home Screen, Action Button, Back Tap, or "Hey Siri, Grok Bot".

Don't share your finished Shortcut: it contains your key.

## Privacy

- Speech is recorded to a temporary WAV and **transcribed on-device** by whisper.cpp; audio is deleted after transcription and is never uploaded.
- Only the transcript, the active Brave tab's URL/title, and (optionally) a recent PointTalk capture are sent, and only to **your** webhook URL.
- The clipboard watcher keeps only text in PointTalk format (starting with `### Element pack` and containing `**Page:**` and `**Target:**` lines). Anything else you copy is ignored, never stored, logged, or sent. A capture is attached to at most one message and expires after 5 minutes (discard it from the menu bar).
- The log (`~/.hammerspoon/voice_ptt.log`) records only state changes, page **hosts** (not full URLs), and sizes in bytes. It never records your transcript, your key, or PointTalk content.
- The extension only runs when you trigger it on the active tab and only writes to your clipboard; it makes no network requests.

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Pat McCormick.

Third-party tools the installer downloads keep their own licenses: whisper.cpp (MIT), nowplaying-cli, ffmpeg, Hammerspoon.
