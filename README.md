# Steam Windows Notifications

**Route Steam in-client notifications to native Windows 11 toast notifications.**

No more missing notifications when Steam is minimized or in the background. This plugin intercepts Steam's notification pipeline and fires real Windows toasts with emoji, theme-aware icons, and deduplication — all with zero console flash.

## Features

- **Native Windows 11 toasts** — Popups appear in the Windows action center, not just inside Steam
- **Emoji by notification type** — Visual cues at a glance:
  - 📥 Downloads & Updates
  - 💬 Chat messages
  - 👤 Friend activity
  - 🏆 Achievements
  - 📸 Screenshots
  - 🎁 Gifts, 🤝 Trades, 📩 Invites, and more
- **Theme-aware icon** — Steam logo automatically switches between black (light theme) and white (dark theme)
- **Toast deduplication** — Repeated notifications (e.g. "Updates Available") replace old toasts instead of stacking
- **Simple on/off toggle** — One click to enable or disable Windows notifications
- **No console window flash** — Uses LuaJIT FFI `CreateProcess` with `CREATE_NO_WINDOW` — no cmd.exe popup
- **Works with Focus Assist** — Toasts appear even when Do Not Disturb is on (Windows 11)

## How It Works

```
Steam notification event
        │
        ▼
Frontend (TypeScript) hooks
  ┌─────────────────────────────┐
  │ NotificationStore           │
  │  • ProcessNotification      │
  │  • OnNewNotificationReceived│
  │  • OnNotification           │
  │                             │
  │ SteamClient                 │
  │  • Downloads                │
  │  • Notifications            │
  │  • GameSessions             │
  └──────────┬──────────────────┘
             │ RPC (JSON string)
             ▼
Backend (Lua)
  ┌─────────────────────────────┐
  │ Parse notification payload  │
  │ Look up emoji by kind       │
  │ Generate PowerShell script  │
  │ Spawn via FFI CreateProcess │
  │   (no console window)       │
  └──────────┬──────────────────┘
             │
             ▼
PowerShell script
  ┌─────────────────────────────┐
  │ Detect Windows theme        │
  │ (registry → SVG fill color) │
  │                             │
  │ Register AUMID display name │
  │ (shows "Steam" not          │
  │  "Windows PowerShell")      │
  │                             │
  │ Fire WinRT toast via        │
  │ ToastNotificationManager   │
  └─────────────────────────────┘
             │
             ▼
    Windows 11 Toast 🪟
```

## Requirements

- [Millennium](https://steambrew.app) (Steam client modding framework)
- Windows 10 or 11

**No other dependencies.** The plugin is fully self-contained — no Node.js, no PowerShell modules (BurntToast etc.), no additional runtimes. Everything is built in and ready to use.

## Installation

### Manual install

1. Download the latest release
2. Extract to `C:\Program Files (x86)\Steam\plugins\steam-win-notify`
3. Open Steam → Settings → Plugins → enable "Windows Notifications"
4. Toggle the plugin off and on once to activate

## Settings

| Setting | Description |
|---------|-------------|
| **Enable Windows notifications** | Master toggle. Off = no toasts sent to Windows. |

The plugin forwards all notification kinds by default. Per-kind filtering can be added back by editing the frontend source.

## Building from source

```bash
git clone https://github.com/SnakyWarrior/steam-win-notify
cd steam-win-notify
npm install
npm run build
```

Copy `.millennium/Dist/index.js` and `backend/main.lua` to your Steam plugins folder.

## Development

- **Frontend:** `frontend/index.tsx` — TypeScript, hooks into Steam's notification store and `SteamClient.*` APIs
- **Backend:** `backend/main.lua` — Lua, receives RPC calls from frontend, generates and spawns PowerShell toast scripts
- **Toast icon:** `steam.svg` — Theme-aware SVG (uses `fill` color based on Windows light/dark mode)

## Files

```
steam-win-notify/
├── plugin.json              # Millennium plugin manifest
├── steam.svg                # Toast logo (theme-aware SVG)
├── backend/
│   └── main.lua             # Lua backend: RPC, toast generation, FFI process spawn
├── frontend/
│   └── index.tsx            # TypeScript frontend: hooks, settings UI
├── .millennium/
│   └── Dist/
│       └── index.js         # Built frontend output
├── package.json             # Build dependencies
├── tsconfig.json            # TypeScript configuration
└── README.md
```

## Credits

This plugin was built collaboratively by human and AI:

- **andigravity** — Concept, testing, feedback, and direction
- **opencode** — AI coding assistant ([opencode.ai](https://opencode.ai))
- **Claude Opus & Sonnet** (Anthropic) — Large language models used during development
- **big pickle** — The model powering opencode sessions

Built for [Millennium](https://steambrew.app), the Steam client modding framework.

## License

MIT
