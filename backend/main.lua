-- steam-win-notify : Lua backend
--
-- Receives notification data from the frontend (which has hooked Steam's
-- internal notification pipeline) and fires a native Windows 11 toast via
-- PowerShell + WinRT toast APIs with the SteamWinNotify AUMID.

local logger     = require("logger")
local millennium = require("millennium")
local json       = require("json")
local fs         = require("fs")
local utils      = require("utils")

-- ---------------------------------------------------------------------------
-- FFI: CreateProcess with CREATE_NO_WINDOW (no console flash)
-- ---------------------------------------------------------------------------
local create_process_no_window
pcall(function()
    local ffi = require("ffi")
    ffi.cdef[[
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef struct {
            DWORD cb; void* lpReserved; void* lpDesktop; void* lpTitle;
            DWORD dwX; DWORD dwY; DWORD dwXSize; DWORD dwYSize;
            DWORD dwXCountChars; DWORD dwYCountChars; DWORD dwFillAttribute;
            DWORD dwFlags; unsigned short wShowWindow; unsigned short cbReserved2;
            void* lpReserved2; HANDLE hStdInput; HANDLE hStdOutput; HANDLE hStdError;
        } STARTUPINFOA;
        typedef struct { HANDLE hProcess; HANDLE hThread; DWORD dwProcessId; DWORD dwThreadId; } PROCESS_INFORMATION;
        BOOL CreateProcessA(const char*, char*, void*, void*, BOOL, DWORD, void*, const char*, STARTUPINFOA*, PROCESS_INFORMATION*);
        DWORD GetLastError(void);
        BOOL CloseHandle(HANDLE);
    ]]
    local K32 = ffi.load("kernel32")
    local si  = ffi.new("STARTUPINFOA")
    si.cb     = ffi.sizeof("STARTUPINFOA")
    local pi  = ffi.new("PROCESS_INFORMATION")

    create_process_no_window = function(cmd)
        local buf = ffi.new("char[?]", #cmd + 1)
        ffi.copy(buf, cmd)
        local ok = K32.CreateProcessA(nil, buf, nil, nil, false, 0x08000000, nil, nil, si, pi)
        if ok == 0 then
            return false, tonumber(K32.GetLastError())
        end
        K32.CloseHandle(pi.hProcess)
        K32.CloseHandle(pi.hThread)
        return true
    end
end)

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local PLUGIN_DIR  = fs.parent_path(utils.get_backend_path())
local CONFIG_PATH = PLUGIN_DIR .. "/config.json"

local DEFAULT_CONFIG = {
    enabled_kinds   = { "*" },
    app_id          = "Valve.Steam",
    cache_images    = true,
}

local CONFIG = {
    enabled_kinds   = { "*" },
    app_id          = "Valve.Steam",
    cache_images    = true,
}

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function load_config()
    local raw = read_file(CONFIG_PATH)
    if raw and raw ~= "" then
        local ok, parsed = pcall(json.decode, raw)
        if ok and type(parsed) == "table" then
            for k, v in pairs(parsed) do
                if DEFAULT_CONFIG[k] ~= nil then
                    CONFIG[k] = v
                end
            end
            return
        end
        logger:warn("[steam-win-notify] config.json parse error, using defaults")
    else
        -- Write defaults so the user can edit them.
        local ok_enc, encoded = pcall(json.encode, DEFAULT_CONFIG)
        if ok_enc then
            pcall(write_file, CONFIG_PATH, encoded)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ps_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "''") .. "'"
end

local function kind_enabled(kind)
    local list = CONFIG.enabled_kinds
    if type(list) ~= "table" then return true end
    for _, k in ipairs(list) do
        if k == "*" or k == kind then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Emoji by notification kind
-- ---------------------------------------------------------------------------
local KIND_EMOJI = {
    chat        = "💬",
    friend      = "👤",
    invite      = "📩",
    achievement = "🏆",
    trade       = "🤝",
    screenshot  = "📸",
    download    = "📥",
    broadcast   = "📡",
    purchase    = "🛒",
    wishlist    = "⭐",
    comment     = "💬",
    gift        = "🎁",
    party       = "🎉",
    generic     = "🔔",
}

local STEAM_ICON = PLUGIN_DIR .. "\\steam.svg"

-- Convert a local path to file:/// URI for toast XML
local function file_uri(path)
    return "file:///" .. path:gsub("\\", "/")
end

-- ---------------------------------------------------------------------------
-- Toast firing
-- ---------------------------------------------------------------------------

local function esc_ps1(s)
    -- Escape string for embedding inside a PowerShell single-quoted string.
    -- In PowerShell '...' strings, the only escape is '' for a literal '.
    return (tostring(s or ""):gsub("'", "''"))
end

local function fire_toast(title, body, image, kind)
    title = tostring(title or "Steam")
    body  = tostring(body or "")
    image = tostring(image or "")
    kind  = tostring(kind or "generic")

    local emoji = KIND_EMOJI[kind] or "🔔"
    title = emoji .. " " .. title

    local appid = tostring(CONFIG.app_id or "Valve.Steam")
    local tmp   = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"

    local script_path = tmp .. "\\steam-toast.ps1"
    local log_path    = tmp .. "\\steam-toast-log.txt"

    -- Escape a string for embedding in a PowerShell single-quoted literal.
    local function esc(s) return "'" .. (tostring(s or ""):gsub("'", "''")) .. "'" end

    -- Build the .ps1 via individual writes (avoids all long-bracket nesting bugs
    -- and cmd.exe quoting issues).  Values are baked directly into the script.
    local ok, written = pcall(function()
        local f = io.open(script_path, "w")
        if not f then return false end

        local function w(s) f:write(s) end
        local function wl(s) f:write(s); f:write("\n") end

        w("\xEF\xBB\xBF") -- UTF-8 BOM so PowerShell reads the file as UTF-8
        w("$log = "); wl(esc(log_path))
        wl("")
        wl([[
function Log($m) {
    "$(Get-Date -Format 'HH:mm:ss.fff') $m" | Out-File $log -Append -Encoding ASCII
}
]])
        wl('Log "== START =="')
        wl("")
        w("$title = "); w(esc(title)); w("; $body = "); w(esc(body))
        w("; $image = "); w(esc(image)); w("; $kind = "); w(esc(kind))
        w("; $appid = "); w(esc(appid)); w("; $icon_src = "); wl(esc(STEAM_ICON))
        wl("")
        wl('Log "title=$title kind=$kind"')
        wl("")
        wl("# ---- Register AUMID display name so it says 'Steam' not 'Windows PowerShell' ----")
        wl("try {")
        wl("    $aumid = 'SteamWinNotify'")
        wl("    $regPath = 'HKCU:\\SOFTWARE\\Classes\\AppUserModelId\\' + $aumid")
        wl("    if (-not (Test-Path $regPath)) {")
        wl("        New-Item -Path $regPath -Force | Out-Null")
        wl("    }")
        wl("    Set-ItemProperty -Path $regPath -Name 'DisplayName' -Value 'Steam' -Force")
        wl("    Set-ItemProperty -Path $regPath -Name 'IconUri' -Value $icon_src -Force")
        wl("    Set-ItemProperty -Path $regPath -Name 'IconBackgroundColor' -Value 'transparent' -Force")
        wl('    Log "AUMID display name set to Steam"')
        wl('} catch { Log "AUMID reg fail: $($_.Exception.Message)" }')

        wl("# ---- Ensure AUMID shortcut exists for WinRT toast ----")
        wl("try {")
        wl("    $sf = Join-Path $env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs'")
        wl("    $lnk = Join-Path $sf 'SteamWinNotify.lnk'")
        wl("    if (-not (Test-Path $lnk)) {")
        wl("        $sh = New-Object -ComObject WScript.Shell")
        wl("        $sc = $sh.CreateShortcut($lnk)")
        wl("        $sc.TargetPath = Join-Path $env:SystemRoot 'system32\\cmd.exe'")
        wl("        $sc.Arguments = '/c exit'")
        wl("        $sc.Save()")
        wl("    }")
wl("} catch { Log 'AUMID shortcut fail: $($_.Exception.Message)' }")
wl("")
wl("# ---- Toast logo: theme-aware SVG ----")
wl("try {")
wl("    $dark = 0")
wl("    $reg = 'HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize'")
wl("    if (Test-Path $reg) { $v = Get-ItemProperty -Path $reg -Name AppsUseLightTheme -ErrorAction Stop; $dark = if ($v.AppsUseLightTheme -eq 0) { 1 } else { 0 } }")
wl("    $fill = if ($dark) { '#ffffff' } else { '#1A1918' }")
wl("    $raw = [System.IO.File]::ReadAllText($icon_src)")
wl("    $raw = $raw -replace 'fill=\"[^\"]*\"', ('fill=\"' + $fill + '\"')")
wl("    $logo = Join-Path $env:TEMP 'sw-logo.svg'")
wl("    [System.IO.File]::WriteAllText($logo, $raw)")
wl("    $logo_uri = 'file:///' + $logo.Replace('\\', '/')")
wl('    Log "Logo: dark=$dark fill=$fill"')
wl('} catch { Log "Logo fail: $($_.Exception.Message)"; $logo_uri = $null }')
wl("")
wl("# ---- WinRT toast ----")
        wl("try {")
        wl("    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]")
        wl("    $xml = '<toast><visual><binding template=\"ToastGeneric\">'")
        wl("    $xml += '<text placement=\"attribution\">Steam</text>'")
        wl("    $xml += '<text>' + [System.Security.SecurityElement]::Escape($title) + '</text>'")
        wl("    if ($body) { $xml += '<text>' + [System.Security.SecurityElement]::Escape($body) + '</text>' }")
        wl("    if ($image) {")
        wl("        $xml += '<image placement=\"appLogoOverride\" src=\"' + [System.Security.SecurityElement]::Escape($image) + '\"/>'")
        wl("    } elseif ($logo_uri) {")
        wl("        $xml += '<image placement=\"appLogoOverride\" src=\"' + [System.Security.SecurityElement]::Escape($logo_uri) + '\"/>'")
        wl("    }")
        wl("    $xml += '</binding></visual></toast>'")
        wl("    $doc = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)")
        wl("    $doc.LoadXml($xml)")
        wl("    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)")
        wl("    $toast.Tag = 'sw' + [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($title + '|' + $body))).Substring(0,16)")
        wl("    $toast.Group = 'Steam'")
        wl("    $toast.ExpirationTime = (Get-Date).AddHours(2)")
        wl("    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid)")
        wl('    Log "ToastNotifier.Setting = $($notifier.Setting)"')
        wl("    $notifier.Show($toast)")
        wl('    Log "WinRT toast sent (AUMID=$aumid)"')
        wl('    Log "Keeping process alive for 2s to ensure toast displays..."')
        wl("    Start-Sleep -Seconds 2")
        wl('    Log "Sleep done"')
        wl('} catch { Log "WinRT toast fail: $($_.Exception.Message)" }')
        wl("")
        wl('Log "== END =="')

        f:close()
        return true
    end)

    if not (ok and written) then
        logger:warn("[steam-win-notify] cannot write ps1 to " .. script_path)
        return
    end

    -- Spawn PowerShell via FFI CreateProcess with CREATE_NO_WINDOW.
    -- This creates the process with NO console window — no flash at all.
    local ps_cmd = 'powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "' .. script_path .. '"'
    local ok_spawn
    if create_process_no_window then
        ok_spawn, _ = create_process_no_window(ps_cmd)
    end
    if not ok_spawn then
        -- Fallback: WMI via VBS + wscript.exe (brief cmd.exe flash, but better than nothing)
        local vbs_path = tmp .. "\\steam-toast-launcher.vbs"
        pcall(function()
            local f = io.open(vbs_path, "w")
            if f then
                f:write('CreateObject("WMI.Win32_Process").Create "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ""'
                    .. script_path .. '"""\n')
                f:close()
            end
        end)
        pcall(os.execute, 'wscript.exe "' .. vbs_path .. '"')
    end
    logger:info("[steam-win-notify] toast done, log -> " .. log_path)
end

-- ---------------------------------------------------------------------------
-- RPC methods (GLOBAL functions, callable from frontend via @steambrew/client)
-- ---------------------------------------------------------------------------
-- The frontend `callable<[{title,body,image_url,kind}]>` passes each field
-- as a positional arg.

function send_notification(payload_json)
    -- RPC bridge receives a JSON string (sent as { payload_json } from frontend).
    local title = "Steam"
    local body = ""
    local image_url = ""
    local kind = "generic"
    if type(payload_json) == "string" and payload_json ~= "" then
        local ok, parsed = pcall(json.decode, payload_json)
        if ok and type(parsed) == "table" then
            title     = tostring(parsed.title or "Steam")
            body      = tostring(parsed.body or "")
            image_url = tostring(parsed.image_url or "")
            kind      = tostring(parsed.kind or "generic")
        end
    end

    logger:info("[steam-win-notify] send_notification: kind=" .. kind .. " title=" .. title)

    if not kind_enabled(kind) then
        return json.encode({ ok = false, skipped = true })
    end

    pcall(fire_toast, title, body, image_url, kind)

    return json.encode({
        ok = true,
    })
end

function get_config()
    return json.encode({
        enabled_kinds   = CONFIG.enabled_kinds or { "*" },
        app_id          = CONFIG.app_id or "Valve.Steam",
        cache_images    = CONFIG.cache_images == true,
    })
end

function reload_config()
    load_config()
    return json.encode({ ok = true })
end

-- Persist settings sent from the frontend settings UI. The frontend passes
-- a JSON-encoded blob in `payload` to avoid type-mismatch problems.
function set_config(payload)
    local ok, parsed = pcall(json.decode, tostring(payload or ""))
    if not ok or type(parsed) ~= "table" then
        return json.encode({ ok = false, error = "bad_payload" })
    end

    -- Merge into CONFIG, but only for known keys.
    for k, v in pairs(parsed) do
        if DEFAULT_CONFIG[k] ~= nil then
            CONFIG[k] = v
        end
    end

    -- Save to disk so settings survive a Steam restart.
    local snapshot = {
        enabled_kinds   = CONFIG.enabled_kinds or { "*" },
        app_id          = CONFIG.app_id or "Valve.Steam",
        cache_images    = CONFIG.cache_images == true,
    }
    local ok_enc, encoded = pcall(json.encode, snapshot)
    if ok_enc then
        pcall(write_file, CONFIG_PATH, encoded)
    end

    return json.encode({ ok = true })
end

-- Test toast helper, callable from the settings UI's "Test" button.
function fire_test_toast()
    logger:info("[steam-win-notify] fire_test_toast called")
    pcall(fire_toast, "Steam Notifications",
        "If you can see this, Windows toasts are working.",
        "", "generic")
    return json.encode({ ok = true })
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function on_load()
    pcall(load_config)
    logger:info("[steam-win-notify] backend loaded")
    millennium.ready()
end

local function on_frontend_loaded()
    logger:info("[steam-win-notify] frontend loaded")
end

local function on_unload()
    logger:info("[steam-win-notify] unloading")
end

return {
    on_load            = on_load,
    on_frontend_loaded = on_frontend_loaded,
    on_unload          = on_unload,
}
