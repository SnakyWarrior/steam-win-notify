param(
    [switch]$Daemon,
    [string]$Title = "",
    [string]$Body = "",
    [string]$Image = "",
    [string]$Kind = "generic"
)

$script:logPath = Join-Path $env:TEMP "steam-toast-log.txt"
$script:aumid = "SteamWinNotify"
$script:iconSrc = Join-Path (Split-Path $PSCommandPath -Parent) "steam.svg"
$script:notifyDir = Join-Path $env:TEMP "sw-notify"

function Log($m) {
    "$(Get-Date -Format 'HH:mm:ss.fff') $m" | Out-File $script:logPath -Append -Encoding ASCII
}

# ---- Emoji by codepoint (avoids encoding issues) ----
$KIND_EMOJI = @{}
$emojiMap = @{
    chat        = 0x1F4AC
    friend      = 0x1F464
    invite      = 0x1F4E9
    achievement = 0x1F3C6
    trade       = 0x1F91D
    screenshot  = 0x1F4F8
    download    = 0x1F4E5
    broadcast   = 0x1F4E1
    purchase    = 0x1F6D2
    wishlist    = 0x2B50
    comment     = 0x1F4AC
    gift        = 0x1F381
    party       = 0x1F389
    controller  = 0x1F3AE
    generic     = 0x1F514
}
foreach ($k in $emojiMap.Keys) {
    $KIND_EMOJI[$k] = [char]::ConvertFromUtf32($emojiMap[$k])
}

# ---- AUMID registration ----
function Ensure-AUMID {
    # Write an AUMID-specific SVG with white fill (always visible)
    $aumidSvg = Join-Path $env:TEMP "sw-aumid-icon.svg"
    $svgContent = @'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 259">
  <path fill="#ffffff" d="M127.779 0C60.42 0 5.24 52.412 0 119.014l68.724 28.674a35.812 35.812 0 0 1 20.426-6.366c.682 0 1.356.019 2.02.056l30.566-44.71v-.626c0-26.903 21.69-48.796 48.353-48.796 26.662 0 48.352 21.893 48.352 48.796 0 26.902-21.69 48.804-48.352 48.804-.37 0-.73-.009-1.098-.018l-43.593 31.377c.028.582.046 1.163.046 1.735 0 20.204-16.283 36.636-36.294 36.636-17.566 0-32.263-12.658-35.584-29.412L4.41 164.654c15.223 54.313 64.673 94.132 123.369 94.132 70.818 0 128.221-57.938 128.221-129.393C256 57.93 198.597 0 127.779 0zM80.352 196.332l-15.749-6.568c2.787 5.867 7.621 10.775 14.033 13.47 13.857 5.83 29.836-.803 35.612-14.799a27.555 27.555 0 0 0 .046-21.035c-2.768-6.79-7.999-12.086-14.706-14.909-6.67-2.795-13.811-2.694-20.085-.304l16.275 6.79c10.222 4.3 15.056 16.145 10.794 26.46-4.253 10.314-15.998 15.195-26.22 10.895zm121.957-100.29c0-17.925-14.457-32.52-32.217-32.52-17.769 0-32.226 14.595-32.226 32.52 0 17.926 14.457 32.512 32.226 32.512 17.76 0 32.217-14.586 32.217-32.512zm-56.37-.055c0-13.488 10.84-24.42 24.2-24.42 13.368 0 24.208 10.932 24.208 24.42 0 13.488-10.84 24.421-24.209 24.421-13.359 0-24.2-10.933-24.2-24.42z"></path>
</svg>
'@
    try { [System.IO.File]::WriteAllText($aumidSvg, $svgContent, [System.Text.Encoding]::UTF8) } catch {}

    $regPath = "HKCU:\SOFTWARE\Classes\AppUserModelId\$script:aumid"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "DisplayName" -Value "Steam" -Force
    Set-ItemProperty -Path $regPath -Name "IconUri" -Value $aumidSvg -Force
    Set-ItemProperty -Path $regPath -Name "IconBackgroundColor" -Value "#171a21" -Force
    $sf = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
    $lnk = Join-Path $sf "SteamWinNotify.lnk"
    if (-not (Test-Path $lnk)) {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = Join-Path $env:SystemRoot "system32\cmd.exe"
        $sc.Arguments = "/c exit"
        $sc.Save()
    }
}

# ---- Theme-aware SVG logo ----
function Get-LogoUri {
    try {
        $dark = 0
        $reg = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        if (Test-Path $reg) { $v = Get-ItemProperty -Path $reg -Name AppsUseLightTheme -ErrorAction Stop; $dark = if ($v.AppsUseLightTheme -eq 0) { 1 } else { 0 } }
        $fill = if ($dark) { "#ffffff" } else { "#1A1918" }
        $raw = [System.IO.File]::ReadAllText($script:iconSrc)
        $raw = $raw -replace 'fill="[^"]*"', ('fill="' + $fill + '"')
        $logo = Join-Path $env:TEMP "sw-logo.svg"
        [System.IO.File]::WriteAllText($logo, $raw)
        return "file:///$($logo.Replace('\', '/'))"
    } catch { return $null }
}

# ---- XInput via embedded C# ----
function Init-XInput {
    $code = @"
using System;
using System.Runtime.InteropServices;
public static class XInput {
    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_GAMEPAD {
        public ushort wButtons; public byte bLeftTrigger; public byte bRightTrigger;
        public short sThumbLX; public short sThumbLY; public short sThumbRX; public short sThumbRY;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_STATE { public uint dwPacketNumber; public XINPUT_GAMEPAD Gamepad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_CAPABILITIES { public byte bType; public byte bSubType; public ushort wFlags; public XINPUT_GAMEPAD Gamepad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_BATTERY_INFORMATION { public byte bType; public byte bLevel; }
    [DllImport("xinput1_4")] public static extern int XInputGetState(int i, out XINPUT_STATE s);
    [DllImport("xinput1_4")] public static extern int XInputGetCapabilities(int i, uint f, out XINPUT_CAPABILITIES c);
    [DllImport("xinput1_4")] public static extern int XInputGetBatteryInformation(int i, byte t, out XINPUT_BATTERY_INFORMATION b);
}
"@
    try { Add-Type -TypeDefinition $code -ErrorAction Stop; return $true }
    catch { Log "XInput init failed: $($_.Exception.Message)"; return $false }
}

$SUBTYPE_NAMES = @{
    1 = "Xbox Controller"; 2 = "Wheel"; 3 = "Arcade Stick"; 4 = "Flight Stick"
    5 = "Dance Pad"; 6 = "Guitar"; 7 = "Guitar"; 8 = "Drum Kit"; 16 = "Arcade Pad"
}

function Get-ControllerName($idx) {
    $cap = New-Object XInput+XINPUT_CAPABILITIES
    $rc = [XInput]::XInputGetCapabilities($idx, 0, [ref]$cap)
    if ($rc -eq 0) { $name = $SUBTYPE_NAMES[[int]$cap.bSubType]; if ($name) { return $name } }
    return "XInput Controller"
}

# ---- Fire a toast ----
function Send-Toast($title, $body, $image, $kind) {
    # Detect controller-related notifications by content keywords
    # so they share the same "sw-controller" tag and replace each other
    if ($kind -ne "controller") {
        $tl = ($title + " " + $body).ToLower()
        if ($tl.Contains("controller") -or $tl.Contains("xinput") -or $tl.Contains("gamepad") -or $tl.Contains("xbox")) {
            $kind = "controller"
        }
    }

    $emoji = $KIND_EMOJI[$kind]; if (-not $emoji) { $emoji = $KIND_EMOJI["generic"] }
    $displayTitle = $emoji + " " + $title

    $xml = '<toast><visual><binding template="ToastGeneric">'
    $xml += '<text placement="attribution">Steam</text>'
    $xml += '<text>' + [System.Security.SecurityElement]::Escape($displayTitle) + '</text>'
    if ($body) { $xml += '<text>' + [System.Security.SecurityElement]::Escape($body) + '</text>' }
    $logoUri = Get-LogoUri
    if ($image) {
        $imageUri = "file:///$($image.Replace('\', '/'))"
        $xml += '<image placement="appLogoOverride" src="' + [System.Security.SecurityElement]::Escape($imageUri) + '"/>'
    } elseif ($logoUri) {
        $xml += '<image placement="appLogoOverride" src="' + [System.Security.SecurityElement]::Escape($logoUri) + '"/>'
    }
    $xml += '</binding></visual></toast>'

    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
        $doc = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $doc.LoadXml($xml)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
        $toast.Tag = "sw-" + $kind
        $toast.Group = "Steam"
        $toast.ExpirationTime = (Get-Date).AddHours(2)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:aumid)
        $notifier.Show($toast)
        Log "Toast: $kind - $title"
    } catch { Log "Toast fail: $($_.Exception.Message)" }
}

# ---- Controller polling ----
$prevControllers = @{}

function Poll-Controllers {
    for ($idx = 0; $idx -lt 4; $idx++) {
        $st = New-Object XInput+XINPUT_STATE
        $connected = ([XInput]::XInputGetState($idx, [ref]$st) -eq 0)
        $cname = if ($connected) { Get-ControllerName $idx } else { "XInput Controller" }
        $display = "$cname #$($idx + 1)"

        $battLevel = 3
        if ($connected) {
            $bi = New-Object XInput+XINPUT_BATTERY_INFORMATION
            $brc = [XInput]::XInputGetBatteryInformation($idx, 0, [ref]$bi)
            if ($brc -eq 0) { $battLevel = [int]$bi.bLevel }
        }

        if (-not $prevControllers.ContainsKey($idx)) {
            $prevControllers[$idx] = @{ connected = $connected; battery = $battLevel; name = $display }
        } else {
            $p = $prevControllers[$idx]
            if ($p.connected -ne $connected) {
                $title = if ($connected) { "Controller connected" } else { "Controller disconnected" }
                Send-Toast $title $display "" "controller"
                $p.name = $display
            }
            $p.connected = $connected

            if ($connected -and $battLevel -ne $p.battery) {
                if ($battLevel -le 1 -and $p.battery -gt 1) {
                    $label = if ($battLevel -eq 0) { "empty" } else { "low" }
                    Send-Toast "Controller battery $label" "$display battery is $label" "" "controller"
                }
            }
            $p.battery = $battLevel
        }
    }
}

# ---- Start ----
$script:xinputOk = Init-XInput
if (-not $script:xinputOk) {
    Log "XInput init failed, controller monitoring disabled"
}

Ensure-AUMID
Log "Daemon started (PID: $pid)"

if (-not $Daemon) {
    Send-Toast $Title $Body $Image $Kind
    Log "One-shot done"
    exit 0
}

# ---- Daemon mode ----
if (-not (Test-Path $script:notifyDir)) { New-Item -ItemType Directory -Path $script:notifyDir -Force | Out-Null }
Log "Entering main loop"

while ($true) {
    $files = Get-ChildItem "$script:notifyDir\*.json" -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $data = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            Send-Toast $data.title $data.body $data.image $data.kind
        } catch { Log "File error: $($f.Name) - $($_.Exception.Message)" }
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    }

    Poll-Controllers

    Start-Sleep -Seconds 2
}
