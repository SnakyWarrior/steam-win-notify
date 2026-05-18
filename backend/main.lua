-- steam-win-notify : Lua backend
--
-- Receives notification data from the frontend and forwards them to a
-- persistent PowerShell daemon that handles both XInput controller
-- monitoring and WinRT toast generation.

local logger     = require("logger")
local millennium = require("millennium")
local json       = require("json")

-- ---------------------------------------------------------------------------
-- Get plugin directory using debug info
-- ---------------------------------------------------------------------------

local function get_plugin_dir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    src = src:gsub("/", "\\")
    local dir = src:match("(.+\\)backend\\")
    return dir or "C:\\Program Files (x86)\\Steam\\plugins\\steam-win-notify\\"
end

local PLUGIN_DIR  = get_plugin_dir()
local CONFIG_PATH = PLUGIN_DIR .. "config.json"
local DAEMON_PATH = PLUGIN_DIR .. "steam-toast-daemon.ps1"

-- ---------------------------------------------------------------------------
-- FFI: CreateProcess with DETACHED_PROCESS | CREATE_NO_WINDOW
-- ---------------------------------------------------------------------------

local run_hidden
local spawn_daemon_process
local _daemon_pid = nil
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
        typedef struct {
            HANDLE hProcess; HANDLE hThread;
            DWORD dwProcessId; DWORD dwThreadId;
        } PROCESS_INFORMATION;
        BOOL CreateProcessA(
            const char*, char*, void*, void*, BOOL, DWORD,
            void*, const char*, STARTUPINFOA*, PROCESS_INFORMATION*
        );
        DWORD GetLastError(void);
        BOOL CloseHandle(HANDLE);
    ]]
    local K32 = ffi.load("kernel32")
    local DETACHED_NO_WINDOW = 0x08000008

    local function create(cmd)
        local si = ffi.new("STARTUPINFOA")
        si.cb   = ffi.sizeof("STARTUPINFOA")
        local pi = ffi.new("PROCESS_INFORMATION")
        local buf = ffi.new("char[?]", #cmd + 1)
        ffi.copy(buf, cmd)
        local ok = K32.CreateProcessA(nil, buf, nil, nil, false, DETACHED_NO_WINDOW, nil, nil, si, pi)
        if ok == 0 then return false, tonumber(K32.GetLastError()) end
        local pid = tonumber(pi.dwProcessId)
        K32.CloseHandle(pi.hProcess)
        K32.CloseHandle(pi.hThread)
        return true, pid
    end

    run_hidden = function(cmd)
        return create(cmd)
    end

    spawn_daemon_process = function(cmd)
        local ok, pid = create(cmd)
        if ok then _daemon_pid = pid end
        return ok, pid
    end
end)

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local DEFAULT_CONFIG = {
    enabled_kinds = { "*" },
    app_id        = "Valve.Steam",
    cache_images  = true,
}

local CONFIG = {
    enabled_kinds = { "*" },
    app_id        = "Valve.Steam",
    cache_images  = true,
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
        local ok_enc, encoded = pcall(json.encode, DEFAULT_CONFIG)
        if ok_enc then
            pcall(write_file, CONFIG_PATH, encoded)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function kind_enabled(kind)
    local list = CONFIG.enabled_kinds
    if type(list) ~= "table" then return true end
    for _, k in ipairs(list) do
        if k == "*" or k == kind then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Toast firing via daemon JSON files
-- ---------------------------------------------------------------------------

local NOTIFY_DIR = (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp") .. "\\sw-notify"

local function fire_toast(title, body, image, kind)
    title = tostring(title or "Steam")
    body  = tostring(body or "")
    image = tostring(image or "")
    kind  = tostring(kind or "generic")

    if run_hidden then
        run_hidden('cmd.exe /c if not exist "' .. NOTIFY_DIR .. '" mkdir "' .. NOTIFY_DIR .. '"')
    else
        pcall(os.execute, 'if not exist "' .. NOTIFY_DIR .. '" mkdir "' .. NOTIFY_DIR .. '" 2>nul')
    end

    local payload = json.encode({
        title = title,
        body  = body,
        image = image,
        kind  = kind,
    })

    local rnd = math.random(100000, 999999)
    local now = os.time()
    local filepath = NOTIFY_DIR .. "\\" .. now .. "_" .. rnd .. ".json"

    local ok = pcall(write_file, filepath, payload)
    if not ok then
        logger:warn("[steam-win-notify] cannot write notification file to " .. filepath)
        return
    end

    logger:info("[steam-win-notify] toast queued: " .. kind .. " - " .. title)
end

-- ---------------------------------------------------------------------------
-- Daemon lifecycle
-- ---------------------------------------------------------------------------

local function spawn_daemon()
    if not spawn_daemon_process then
        logger:warn("[steam-win-notify] FFI not available, cannot spawn daemon")
        return false, "no_ffi"
    end

    local cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. DAEMON_PATH .. '" -Daemon'
    local ok, pid_or_err = spawn_daemon_process(cmd)
    if ok then
        logger:info("[steam-win-notify] daemon spawned (PID: " .. tostring(pid_or_err) .. ")")
        return true, pid_or_err
    else
        logger:warn("[steam-win-notify] daemon spawn failed (error: " .. tostring(pid_or_err) .. ")")
        return false, pid_or_err
    end
end

local function kill_daemon()
    if not _daemon_pid then return end
    if run_hidden then
        run_hidden('taskkill /F /PID ' .. tostring(_daemon_pid) .. ' 2>nul')
    else
        pcall(os.execute, 'taskkill /F /PID ' .. tostring(_daemon_pid) .. ' 2>nul')
    end
    logger:info("[steam-win-notify] daemon killed (PID: " .. tostring(_daemon_pid) .. ")")
    _daemon_pid = nil
end

-- ---------------------------------------------------------------------------
-- RPC functions (called from frontend)
-- ---------------------------------------------------------------------------

function send_notification(payload_json)
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

    return json.encode({ ok = true })
end

function get_config()
    return json.encode({
        enabled_kinds = CONFIG.enabled_kinds or { "*" },
        app_id        = CONFIG.app_id or "Valve.Steam",
        cache_images  = CONFIG.cache_images == true,
    })
end

function reload_config()
    load_config()
    return json.encode({ ok = true })
end

function set_config(payload)
    local ok, parsed = pcall(json.decode, tostring(payload or ""))
    if not ok or type(parsed) ~= "table" then
        return json.encode({ ok = false, error = "bad_payload" })
    end

    for k, v in pairs(parsed) do
        if DEFAULT_CONFIG[k] ~= nil then
            CONFIG[k] = v
        end
    end

    local snapshot = {
        enabled_kinds = CONFIG.enabled_kinds or { "*" },
        app_id        = CONFIG.app_id or "Valve.Steam",
        cache_images  = CONFIG.cache_images == true,
    }
    local ok_enc, encoded = pcall(json.encode, snapshot)
    if ok_enc then
        pcall(write_file, CONFIG_PATH, encoded)
    end

    return json.encode({ ok = true })
end

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
    pcall(spawn_daemon)
    logger:info("[steam-win-notify] backend loaded (plugin dir: " .. PLUGIN_DIR .. ")")
    millennium.ready()
end

local function on_frontend_loaded()
    logger:info("[steam-win-notify] frontend loaded")
end

local function on_unload()
    pcall(kill_daemon)
    logger:info("[steam-win-notify] unloading")
end

return {
    on_load            = on_load,
    on_frontend_loaded = on_frontend_loaded,
    on_unload          = on_unload,
}
