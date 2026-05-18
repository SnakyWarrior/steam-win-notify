# Steam Windows Notifications

**Route Steam in-client notifications to native Windows 11 toast notifications.**

No more missing notifications when Steam is minimized or in the background. This plugin intercepts Steam's notification pipeline and fires real Windows toasts with emoji, theme-aware icons, and deduplication — all with zero console flash. Also monitors controller connect/disconnect/battery via XInput polling in a background daemon.

## Features

- **Native Windows 11 toasts** — Popups appear in the Windows action center, not just inside Steam
- **Emoji by notification type** — Visual cues at a glance:
  - 📥 Downloads & Updates
  - 💬 Chat messages
  - 👤 Friend activity
  - 🏆 Achievements
  - 📸 Screenshots
  - 🎁 Gifts, 🤝 Trades, 📩 Invites, 🎮 Controller, and more
- **Theme-aware icon** — Steam logo automatically switches between black (light theme) and white (dark theme)
- **Toast deduplication** — Notifications of the same type replace each other (e.g. two downloads → only latest toast)
- **Controller monitoring** — Background daemon polls XInput every 2 seconds; fires toasts on connect, disconnect, and low battery
- **Simple on/off toggle** — One click to enable or disable Windows notifications
- **No console window flash** — Uses LuaJIT FFI `CreateProcess` with `DETACHED_PROCESS | CREATE_NO_WINDOW` — zero popup
- **Works with Focus Assist** — Toasts appear even when Do Not Disturb is on (Windows 11)

## How It Works

```
┌─────────────────────────────────────────────────────┐
│ Steam notification event                             │
│ (NotificationStore, SteamClient callbacks)           │
└────────────────────┬────────────────────────────────┘
                     │ Frontend hooks extract title/body/kind
                     ▼
┌─────────────────────────────────────────────────────┐
│ Lua Backend (FFI CreateProcess → no console flash)   │
│                                                      │
│  ┌─ Spawn daemon on Steam startup (DETACHED_PROCESS) │
│  │   steam-toast-daemon.ps1                          │
│  │   ┌────────────────────────────────────┐          │
│  │   │  Loop every 2 seconds:             │          │
│  │   │  • Poll XInput for controller      │          │
│  │   │  • Process JSON notification files │          │
│  │   │  • Fire WinRT toasts               │          │
│  │   └────────────┬───────────────────────┘          │
│  │                ▼                                  │
│  │          Windows 11 Toast 🪟                      │
│  └───────────────────────────────────────────────────┘
│                                                      │
│  ┌─ Fire one-shot notifications via JSON files ──────┤
│  │   Write JSON to %TEMP%\sw-notify\                 │
│  │   Daemon picks up → fires toast                   │
│  └───────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────┘
```

## Requirements

- [Millennium](https://steambrew.app) (Steam client modding framework)
- Windows 10 or 11

**No other dependencies.** The plugin is fully self-contained — no Node.js, no PowerShell modules, no additional runtimes.

## Installation

### Manual install

1. Download the latest release from [GitHub Releases](https://github.com/SnakyWarrior/steam-win-notify/releases)
2. Extract to `C:\Program Files (x86)\Steam\plugins\steam-win-notify`
3. Open Steam → Settings → Plugins → enable "Windows Notifications"
4. Toggle the plugin off and on once to activate

## Settings

| Setting | Description |
|---------|-------------|
| **Enable Windows notifications** | Master toggle. Off = no toasts sent to Windows. |

## Building from source

```bash
git clone https://github.com/SnakyWarrior/steam-win-notify
cd steam-win-notify
npm install
npm run build
```

Copy `.millennium/Dist/index.js`, `backend/main.lua`, `steam-toast-daemon.ps1`, and `steam.svg` to your Steam plugins folder.

## Development

- **Frontend:** `frontend/index.tsx` — TypeScript, hooks into Steam's notification store and `SteamClient.*` APIs
- **Backend:** `backend/main.lua` — Lua, receives RPC calls from frontend, manages daemon lifecycle
- **Daemon:** `steam-toast-daemon.ps1` — PowerShell background process, polls XInput and fires WinRT toasts
- **Toast icon:** `steam.svg` — Theme-aware SVG (uses `fill` color based on Windows light/dark mode)

## Changelog

### v1.0.0 — Initial release
- Hook NotificationStore methods (`ProcessNotification`, `OnNewNotificationReceived`, `OnNotification`)
- Hook SteamClient callbacks (downloads, achievements, screenshots, chat, notifications)
- Forward notifications to Lua backend via RPC
- Fire native Windows toasts via PowerShell + WinRT (`ToastNotificationManager`)
- Theme-aware SVG icon (reads Windows light/dark mode from registry)
- Settings panel with enable/disable toggle
- UTF-8 BOM for emoji support in PowerShell scripts
- FFI `CreateProcess` with `CREATE_NO_WINDOW` for silent spawning

### v1.1.0 — Daemon architecture
- Replaced per-toast PowerShell scripts with a persistent background daemon (`steam-toast-daemon.ps1`)
- Daemon polls XInput every 2 seconds for controller connect/disconnect/battery events
- Daemon processes JSON notification files written by the Lua backend
- Toast tag uses notification kind (`sw-{kind}`) so same-type notifications replace each other
- Controller keyword detection in daemon ensures controller toasts always use `sw-controller` tag
- `DETACHED_PROCESS | CREATE_NO_WINDOW` (0x08000008) flags eliminate ALL console flash
- All `os.execute` calls replaced with FFI `CreateProcess` (no cmd.exe at any point)
- AUMID icon uses white fill on `#171a21` background for consistent visibility in dark/light themes
- Cleaned up unused code (XInput polling from Lua, `SC.Input` hooks, mode dropdown, suppress-native)

## Credits

This plugin was built collaboratively by human and AI:

- **andigravity** — Concept, testing, feedback, and direction
- **opencode** — AI coding assistant ([opencode.ai](https://opencode.ai))
- **Claude Opus & Sonnet** (Anthropic) — Large language models used during development
- **big pickle** — The model powering opencode sessions

Built for [Millennium](https://steambrew.app), the Steam client modding framework.

## License

MIT
