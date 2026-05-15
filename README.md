# steam-win-notify

A [Millennium](https://steambrew.app/) plugin that routes **all** of Steam's
in-client notifications to the **native Windows 11 notification system**
(Action Center toasts).

## Features

- Catches every kind of Steam notification:
  - Friend chat messages
  - Friend requests / online events
  - Game / lobby / party invites
  - **Achievement unlocks** (with hero art)
  - Trade offers
  - Screenshots taken (with preview)
  - Download complete
  - Broadcasts, wishlist sales, gifts, comments, etc.
- Per-kind toast layouts (hero image for achievements, app-logo avatar for chat, etc.)
- Configurable: keep Steam's built-in popups OR suppress them so only Windows toasts show.
- Per-kind filtering.

---

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 (PowerShell 5.1+) |
| Millennium | latest (Lua backend support) |
| PowerShell module | [BurntToast](https://github.com/Windos/BurntToast) (recommended) |
| Node.js | 18+ (for building the frontend bundle) |

The plugin will fall back to raw WinRT toast XML if BurntToast isn't installed,
but BurntToast gives nicer rendering.

---

## Installation

### 1. Install BurntToast (one time, recommended)

Open PowerShell and run:

```powershell
Install-Module -Name BurntToast -Scope CurrentUser -Force
```

If you skip this step, the plugin will still work via a built-in WinRT fallback.

### 2. Place the plugin folder

This folder should live at:

```
C:\Program Files (x86)\Steam\plugins\steam-win-notify\
```

### 3. Build the frontend bundle

Millennium loads a compiled JS bundle from `.millennium/Dist/index.js`, not
the raw TypeScript. Open a terminal in the plugin folder and run:

```cmd
npm install
npm run build
```

That produces `.millennium/Dist/index.js`. You only need to rerun `npm run build`
when you change the frontend code.

### 4. Enable in Steam

Steam → **Millennium** → **Plugins** → enable **Windows Notifications** → restart Steam.

You should see `[steam-win-notify] backend loaded` in
`C:\Program Files (x86)\Steam\ext\logs\steam-win-notify_log.log`.

---

## Configuration

A `config.json` is created at the plugin root on first run:

```json
{
  "suppress_native": false,
  "enabled_kinds": ["*"],
  "app_id": "Valve.Steam",
  "cache_images": true
}
```

| Key | Description |
|---|---|
| `suppress_native` | If `true`, Steam's own in-client popups are hidden — only Windows toasts appear. |
| `enabled_kinds` | List of notification kinds to forward. `["*"]` = everything. |
| `app_id` | Windows AppUserModelID used for the toast. `Valve.Steam` makes the toast appear under "Steam" in Action Center. |
| `cache_images` | Cache remote images locally so toasts render reliably. |

Recognized kinds:
`chat`, `friend`, `invite`, `achievement`, `trade`, `screenshot`,
`download`, `broadcast`, `purchase`, `wishlist`, `comment`,
`moderator`, `gift`, `party`, `generic`.

Edit the file, then restart Steam or invoke the live-reload RPC from the
Millennium console:

```js
MILLENNIUM_BACKEND_IPC.postMessage(0, {
  pluginName: "steam-win-notify",
  methodName: "reload_config",
  argumentList: { "": "" }
})
```

---

## File structure

```
steam-win-notify/
├── plugin.json                  # Millennium manifest (backendType: "lua")
├── config.json                  # User-editable settings
├── package.json                 # Build deps (@steambrew/*)
├── tsconfig.json                # TS → .millennium/Dist/index.js
├── frontend/
│   └── index.tsx                # Hooks Steam's notification paths, calls backend
└── backend/
    └── main.lua                 # Receives RPC, fires Windows toasts via PowerShell
```

After `npm run build` you'll also have:

```
.millennium/Dist/index.js        # Compiled frontend bundle (what Millennium loads)
node_modules/                    # npm deps
```

---

## How it works

```
              ┌────────────────────────────────────────────┐
              │  Steam events                               │
              │  ─ NotificationStore.ShowNotification        │
              │  ─ AchievementStore.ShowAchievement…         │
              │  ─ SteamClient.Notifications callback        │
              │  ─ SteamClient.Apps achievement callback     │
              │  ─ SteamClient.Downloads callback            │
              │  ─ SteamClient.GameSessions screenshots      │
              │  ─ SteamClient chat / messaging              │
              └───────────────────────┬────────────────────┘
                                      │ extract title/body/image + kind
                                      ▼
                  frontend/index.tsx ──► callable("send_notification")
                                                  │
                                                  ▼
                                      backend/main.lua  (LuaJIT)
                                                  │
                                                  ▼
                                  powershell.exe + BurntToast
                                                  │
                                                  ▼
                                Windows Action Center toast 🔔
```

If `suppress_native` is true, the frontend patches return early so Steam's
built-in popup never renders — you only see the Windows toast.

---

## Troubleshooting

**No toasts appear**
- Check `Steam\ext\logs\steam-win-notify_log.log` — every hook prints `Hooked …` on success.
- Try running this in PowerShell directly to verify BurntToast works:
  ```powershell
  Import-Module BurntToast; New-BurntToastNotification -Text 'Hi','It works!' -AppId 'Valve.Steam'
  ```
- If BurntToast is missing, the plugin falls back to raw WinRT — toasts should still appear.

**Steam still shows its own popups in addition to Windows toasts**
- This is intentional by default. Set `"suppress_native": true` in `config.json`.

**`[steam-win-notify] Gave up after N attempts` in logs**
- One of the Steam internal modules wasn't found. The plugin still works via
  the other hooks (`SteamClient` callbacks), so most notifications still
  forward. Open an issue with your Steam version if a specific kind is missing.

**Steam won't launch after enabling the plugin**
- Disable it by editing `C:\Program Files (x86)\Steam\ext\config.json` and
  removing `"steam-win-notify"` from `plugins.enabledPlugins`, then relaunch
  Steam and check the log for an error message.
