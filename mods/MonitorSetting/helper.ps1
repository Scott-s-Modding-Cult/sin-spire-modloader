# Keeps the Sin Spire window on the monitor named in monitor.txt, and lists monitors for the menu.
# It exits when the game exits.
$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
$gameName = "SinSpire-Win64-Shipping"
$gameTitle = "Sin Spire"
$settings = Join-Path $env:LOCALAPPDATA "SinSpire\Saved\Config\Windows\GameUserSettings.ini"
$reassertSeconds = 30 # The game can reposition its window while it starts up.

$mutex = New-Object System.Threading.Mutex($false, "SinSpireMonitorSettingHelper")
if (-not $mutex.WaitOne(0)) { exit }

function Log($message) { "$(Get-Date -Format s) $message" | Add-Content (Join-Path $dir "helper.log") }

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SinSpireWindow {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
"@

function Get-Monitors {
    # Windows numbers each display in its device name, such as \\.\DISPLAY2.
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        [pscustomobject]@{
            Number = [int]($_.DeviceName -replace '\D', '')
            Bounds = $_.Bounds
            Primary = $_.Primary
        }
    } | Sort-Object Number
}

function Is-ExclusiveFullscreen {
    if (-not (Test-Path $settings)) { return $false }
    return [bool](Select-String -Path $settings -Pattern '^FullscreenMode=0' -Quiet)
}

function Move-Game($hwnd, $monitor) {
    $rect = New-Object SinSpireWindow+RECT
    [void][SinSpireWindow]::GetWindowRect($hwnd, [ref]$rect)
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $target = $monitor.Bounds
    if ($rect.Left -eq $target.X -and $rect.Top -eq $target.Y -and $width -eq $target.Width -and $height -eq $target.Height) { return }

    # A borderless window fills its monitor, so it takes the new monitor's size. A smaller window keeps its size.
    $fills = $null -ne ($monitors | Where-Object { $_.Bounds.Width -eq $width -and $_.Bounds.Height -eq $height })
    if ($fills) {
        $x, $y, $width, $height = $target.X, $target.Y, $target.Width, $target.Height
    } else {
        $x = $target.X + [Math]::Max(0, ($target.Width - $width) / 2)
        $y = $target.Y + [Math]::Max(0, ($target.Height - $height) / 2)
    }
    # SWP_NOZORDER | SWP_NOACTIVATE, so the move does not change which window has focus.
    $moved = [SinSpireWindow]::SetWindowPos($hwnd, [IntPtr]::Zero, [int]$x, [int]$y, [int]$width, [int]$height, 0x0014)
    Log "Moved to monitor $($monitor.Number) at $x,$y ${width}x$height ok=$moved"
}

$monitors = @(Get-Monitors)
$lines = foreach ($monitor in $monitors) {
    $primary = if ($monitor.Primary) { ", primary" } else { "" }
    "$($monitor.Number)|$($monitor.Bounds.Width)x$($monitor.Bounds.Height)$primary"
}
Set-Content -Path (Join-Path $dir "monitors.txt") -Value $lines -Encoding ascii

$start = Get-Date
$applied = 0
$warned = $false
$seenGame = $false
while ($true) {
    $game = Get-Process -Name $gameName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $game) {
        if ($seenGame -or ((Get-Date) - $start).TotalSeconds -gt 60) { break }
        Start-Sleep -Milliseconds 500
        continue
    }
    $seenGame = $true
    $hwnd = $game.MainWindowHandle
    $wanted = [int]((Get-Content (Join-Path $dir "monitor.txt") -TotalCount 1 -ErrorAction SilentlyContinue) -as [int])
    $monitor = $monitors | Where-Object { $_.Number -eq $wanted } | Select-Object -First 1
    $settling = ((Get-Date) - $start).TotalSeconds -lt $reassertSeconds
    # The title check leaves other windows alone, such as the crash reporter's dialog.
    if ($hwnd -ne [IntPtr]::Zero -and $game.MainWindowTitle.Trim() -eq $gameTitle -and $monitor -and ($settling -or $wanted -ne $applied)) {
        if (Is-ExclusiveFullscreen) {
            if (-not $warned) { Log "Skipped: exclusive fullscreen cannot be moved"; $warned = $true }
        } else {
            Move-Game $hwnd $monitor
            $applied = $wanted
        }
    }
    Start-Sleep -Milliseconds 250
}
