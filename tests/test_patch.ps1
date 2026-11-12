# Exercises the patch and launcher on a fake game folder. No real game files are touched.
$ErrorActionPreference = "Stop"
$scratch = Join-Path $env:TEMP "sinspire_modloader_test"; New-Item -ItemType Directory -Force $scratch | Out-Null
$patch = "$PSScriptRoot\..\dist\SinSpire-ModLoader-Patch.exe"
$fake = "$scratch\fake game"
$script:failures = 0
function Check($name, $ok) { if ($ok) { "ok    $name" } else { "FAIL  $name"; $script:failures++ } }
function Run-Patch($mode) { (Start-Process $patch -ArgumentList $mode, "`"$fake`"" -Wait -PassThru).ExitCode }
function Launch {
    Remove-Item "$fake\launched.txt" -ErrorAction SilentlyContinue
    # Shift held at this moment opens the Mod Manager instead, so close it and try again.
    for ($try = 0; $try -lt 5; $try++) {
        $launcher = Start-Process "$fake\SinSpire.exe" -ArgumentList "-testarg" -PassThru
        if ($launcher.WaitForExit(8000)) { break }
        Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 40 -and -not (Test-Path "$fake\launched.txt"); $i++) { Start-Sleep -Milliseconds 100 }
}

if (Test-Path $fake) { cmd /c rmdir /s /q "`"$fake`"" }
$win64 = "$fake\SinSpire\Binaries\Win64"
New-Item -ItemType Directory -Force $win64, "$fake\SinSpire\Content\Paks\~mods" | Out-Null
$source = 'class P { static void Main(string[] a) { System.IO.File.WriteAllText(System.AppDomain.CurrentDomain.BaseDirectory + "launched.txt", string.Join(" ", a)); } }'
Set-Content "$scratch\fake.cs" $source
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe "/out:$fake\SinSpire.exe" "$scratch\fake.cs"
$originalHash = (Get-FileHash "$fake\SinSpire.exe").Hash
Set-Content "$win64\SinSpire-Win64-Shipping.exe" "fake"

# --- A folder with no UE4SS gets it from the patch, and a pak dropped in by hand is adopted.
Set-Content "$fake\SinSpire\Content\Paks\~mods\SinSpire-Loose_P.pak" "pak"
Set-Content "$fake\SinSpire\Content\Paks\~mods\SinSpire-Loose_P.utoc" "toc"
"Exit: " + (Run-Patch "--patch")
Check "UE4SS installed" (Test-Path "$win64\ue4ss\UE4SS.dll")
Check "proxy dll installed" (Test-Path "$win64\dwmapi.dll")
Check "no log in payload" (-not (Test-Path "$win64\ue4ss\UE4SS.log"))
$realFolders = Get-ChildItem "$win64\ue4ss\Mods" -Directory | Where-Object { $_.Attributes -notmatch "ReparsePoint" }
Check "only UE4SS's own mods are real folders" ($realFolders.Count -eq 9)
Check "preset installed" (Test-Path "$fake\Mods\AdminPanel\Scripts\main.lua")
Check "credits installed" (Test-Path "$fake\Mods\CREDITS.txt")
Check "preset pak linked" (Test-Path "$fake\SinSpire\Content\Paks\~mods\SinSpire-CrabPair_P.pak")
Check "preset on by default is running" ((Get-Content "$win64\ue4ss\Mods\mods.txt") -contains "AdminPanel : 1")
Check "preset off by default is listed but off" ((Test-Path "$fake\Mods\CreeperPair\mod.json") -and -not (Test-Path "$win64\ue4ss\Mods\CreeperPair"))
Check "no personal settings in presets" (-not (Get-ChildItem "$fake\Mods" -Recurse -File -Include settings.txt, monitor.txt, monitors.txt, helper.log))
Set-Content "$fake\Mods\AdminPanel\Scripts\main.lua" "-- edited by the player"
Set-Content "$fake\Mods\CrabPair\settings.txt" "keep=1"
Check "original exe kept" ((Get-FileHash "$fake\SinSpire-Original.exe").Hash -eq $originalHash)
Check "exe replaced" ((Get-Item "$fake\SinSpire.exe").VersionInfo.ProductName -eq "SinSpire Mod Loader")
Check "loose pak adopted" (Test-Path "$fake\Mods\Loose\Paks\SinSpire-Loose_P.pak")
Check "loose pak linked back" (Test-Path "$fake\SinSpire\Content\Paks\~mods\SinSpire-Loose_P.pak")
Check "ModKit library linked" (Test-Path "$win64\ue4ss\Mods\shared\ModKit\ModKit.lua")
Check "ModSettings library linked" (Test-Path "$win64\ue4ss\Mods\shared\ModSettings\ModSettings.lua")

# --- Old style mods are moved in, keeping on and off. A rerun of the patch must be safe.
foreach ($m in "OldOn", "OldOff") { New-Item -ItemType Directory -Force "$win64\ue4ss\Mods\$m\Scripts" | Out-Null; Set-Content "$win64\ue4ss\Mods\$m\Scripts\main.lua" "-- $m" }
Set-Content "$win64\ue4ss\Mods\OldOn\enabled.txt" ""
Set-Content "$win64\ue4ss\Mods\OldOn\settings.txt" "keep=1"
"Exit: " + (Run-Patch "--patch")
Check "repatch keeps original exe" ((Get-FileHash "$fake\SinSpire-Original.exe").Hash -eq $originalHash)
Check "repatch keeps a newer mod file" ((Get-Content "$fake\Mods\AdminPanel\Scripts\main.lua") -eq "-- edited by the player")
Check "repatch keeps player settings" ((Get-Content "$fake\Mods\CrabPair\settings.txt") -eq "keep=1")
Check "enabled mod is a junction" ((Get-Item "$win64\ue4ss\Mods\OldOn").Attributes -match "ReparsePoint")
Check "settings reachable through junction" ((Get-Content "$win64\ue4ss\Mods\OldOn\settings.txt") -eq "keep=1")
Check "enabled.txt stripped" (-not (Test-Path "$fake\Mods\OldOn\enabled.txt"))
Check "disabled mod not deployed" (-not (Test-Path "$win64\ue4ss\Mods\OldOff"))
Check "disabled mod remembered" ((Get-Content "$fake\Mods\modlist.txt") -contains "-OldOff")
$txt = Get-Content "$win64\ue4ss\Mods\mods.txt"
Check "mods.txt lists enabled mod" ($txt -contains "OldOn : 1")
Check "mods.txt omits disabled mod" (-not ($txt -match "OldOff"))
Check "mods.txt keeps builtin flags" ($txt -contains "SplitScreenMod : 0")
Check "Keybinds stays last" ($txt[-1] -eq "Keybinds : 1")

# --- The launcher deploys, passes arguments on, and honours order, needs and manifests.
New-Item -ItemType Directory -Force "$fake\Mods\NeedsIt\Scripts", "$fake\Mods\Base\Scripts", "$fake\Mods\Broken\Scripts", "$fake\Mods\Orphan\Scripts" | Out-Null
foreach ($m in "NeedsIt", "Base", "Broken", "Orphan") { Set-Content "$fake\Mods\$m\Scripts\main.lua" "-- $m" }
Set-Content "$fake\Mods\NeedsIt\mod.json" '{"title":"Needs It","version":"2.0","requires":["Base"],"keys":["F2"]}'
Set-Content "$fake\Mods\Base\mod.json" '{"keys":["F2"]}'
Add-Content "$fake\Mods\modlist.txt" "+NeedsIt"
Add-Content "$fake\Mods\modlist.txt" "+Base"
Set-Content "$fake\Mods\Broken\mod.json" '{"title":"Broken", oops'
Add-Content "$fake\Mods\modlist.txt" "-Broken"
Set-Content "$fake\Mods\Orphan\mod.json" '{"requires":["Nothing"],"enabled_by_default":false}'
Launch
Check "game started" (Test-Path "$fake\launched.txt")
Check "arguments passed" ((Get-Content "$fake\launched.txt") -match "-testarg")
$txt = Get-Content "$win64\ue4ss\Mods\mods.txt"
Check "requires reorders" ([array]::IndexOf($txt, "Base : 1") -lt [array]::IndexOf($txt, "NeedsIt : 1") -and [array]::IndexOf($txt, "Base : 1") -ge 0)
Check "disabled by default" (-not ($txt -match "Orphan"))
$log = Get-Content "$fake\Mods\.modloader\modloader.log" -Raw
Check "key clash logged" ($log -match "F2 key is used by Base and NeedsIt")
$modKitVersion = (Get-Content "$PSScriptRoot\..\core\ModKit\mod.json" -Raw | ConvertFrom-Json).version
Check "ModKit in loaded list" ((Get-Content "$fake\Mods\.modloader\loaded.txt") -match "^ModKit=$([regex]::Escape($modKitVersion))$")

# --- Turning a mod off takes it away, and a pak stops being linked.
(Get-Content "$fake\Mods\modlist.txt") -replace "^\+OldOn$", "-OldOn" -replace "^\+Loose$", "-Loose" | Set-Content "$fake\Mods\modlist.txt"
Launch
Check "turned off mod removed" (-not (Test-Path "$win64\ue4ss\Mods\OldOn"))
Check "its files survive" (Test-Path "$fake\Mods\OldOn\settings.txt")
Check "turned off pak unlinked" (-not (Test-Path "$fake\SinSpire\Content\Paks\~mods\SinSpire-Loose_P.pak"))
Check "turned off pak survives" (Test-Path "$fake\Mods\Loose\Paks\SinSpire-Loose_P.pak")
(Get-Content "$fake\Mods\modlist.txt") -replace "^-OldOn$", "+OldOn" -replace "^-Loose$", "+Loose" | Set-Content "$fake\Mods\modlist.txt"
Launch

# --- A file the player placed in the pak folder themselves is not disturbed, unless it collides.
Set-Content "$fake\SinSpire\Content\Paks\~mods\Mine_P.pak" "mine"
Launch
Check "player's own pak kept" (Test-Path "$fake\SinSpire\Content\Paks\~mods\Mine_P.pak")

# --- A Steam update puts the real exe back. The patch must take the new one as the backup.
Remove-Item "$fake\SinSpire.exe"
Copy-Item "$fake\SinSpire-Original.exe" "$fake\SinSpire.exe"
Add-Content "$fake\SinSpire.exe" "newer" -Encoding ascii
$newerHash = (Get-FileHash "$fake\SinSpire.exe").Hash
"Exit: " + (Run-Patch "--patch")
Check "updated exe becomes the backup" ((Get-FileHash "$fake\SinSpire-Original.exe").Hash -eq $newerHash)

# --- Removing the patch restores the exe, removes what it added, and keeps the mods.
"Exit: " + (Run-Patch "--unpatch")
Check "exe restored" ((Get-FileHash "$fake\SinSpire.exe").Hash -eq $newerHash)
Check "backup gone" (-not (Test-Path "$fake\SinSpire-Original.exe"))
Check "UE4SS removed" (-not (Test-Path "$win64\ue4ss"))
Check "proxy removed" (-not (Test-Path "$win64\dwmapi.dll"))
Check "links removed" (-not (Test-Path "$fake\SinSpire\Content\Paks\~mods\SinSpire-Loose_P.pak"))
Check "mods kept" (Test-Path "$fake\Mods\OldOn\Scripts\main.lua")
Check "paks kept" (Test-Path "$fake\Mods\Loose\Paks\SinSpire-Loose_P.pak")
Check "player's pak was adopted by the repatch and kept" (Test-Path "$fake\Mods\Mine\Paks\Mine_P.pak")

# --- A UE4SS too old for the mods (like 3.0.1 stable) is updated, and removing the patch puts it back.
New-Item -ItemType Directory -Force "$win64\ue4ss\Mods\shared\UEHelpers", "$win64\ue4ss\Mods\TheirMod\Scripts" | Out-Null
Set-Content "$win64\dwmapi.dll" "old proxy"
Set-Content "$win64\ue4ss\UE4SS.dll" "old dll"
Set-Content "$win64\ue4ss\UE4SS-settings.ini" "their settings"
Set-Content "$win64\ue4ss\Mods\shared\UEHelpers\UEHelpers.lua" "-- old helpers"
Set-Content "$win64\ue4ss\Mods\TheirMod\Scripts\main.lua" "-- theirs"
Set-Content "$win64\ue4ss\Mods\TheirMod\enabled.txt" ""
"Exit: " + (Run-Patch "--patch")
Check "old UE4SS replaced" ((Select-String -Path "$win64\ue4ss\UE4SS.dll" -Pattern "LoopInGameThreadWithDelay" -SimpleMatch -Quiet))
Check "old proxy replaced" ((Get-Content "$win64\dwmapi.dll" -Raw) -notmatch "old proxy")
Check "old helpers replaced" ((Get-Content "$win64\ue4ss\Mods\shared\UEHelpers\UEHelpers.lua" -Raw) -notmatch "old helpers")
Check "their UE4SS settings kept" ((Get-Content "$win64\ue4ss\UE4SS-settings.ini") -eq "their settings")
Check "old UE4SS backed up" ((Get-Content "$fake\Mods\.modloader\ue4ss_before_patch\ue4ss\UE4SS.dll") -eq "old dll")
Check "their mod adopted" ((Test-Path "$fake\Mods\TheirMod\Scripts\main.lua") -and ((Get-Content "$win64\ue4ss\Mods\mods.txt") -contains "TheirMod : 1"))
"Exit: " + (Run-Patch "--patch")
Check "repatch leaves the updated UE4SS" ((Get-Content "$fake\Mods\.modloader\ue4ss_before_patch\ue4ss\UE4SS.dll") -eq "old dll")
"Exit: " + (Run-Patch "--unpatch")
Check "old UE4SS put back" ((Get-Content "$win64\ue4ss\UE4SS.dll") -eq "old dll")
Check "old proxy put back" ((Get-Content "$win64\dwmapi.dll") -eq "old proxy")
Check "old helpers put back" ((Get-Content "$win64\ue4ss\Mods\shared\UEHelpers\UEHelpers.lua") -eq "-- old helpers")
Check "files the update added removed" (-not (Test-Path "$win64\ue4ss\Mods\Keybinds\Scripts\main.lua"))
Check "their settings still there" ((Get-Content "$win64\ue4ss\UE4SS-settings.ini") -eq "their settings")
Check "UE4SS backup gone" (-not (Test-Path "$fake\Mods\.modloader\ue4ss_before_patch"))

# --- UE4SS 3.0.1 stable keeps its files straight in Win64. Its proxy would load that copy, so it is moved aside.
cmd /c rmdir /s /q "`"$win64\ue4ss`""
New-Item -ItemType Directory -Force "$win64\Mods\FlatOn\Scripts", "$win64\Mods\FlatOff\Scripts", "$win64\Mods\Keybinds\Scripts" | Out-Null
Set-Content "$win64\dwmapi.dll" "flat proxy"
Set-Content "$win64\UE4SS.dll" "flat dll"
Set-Content "$win64\UE4SS-settings.ini" "flat settings"
Set-Content "$win64\Mods\mods.txt" "FlatOn : 1", "FlatOff : 0", "", "; Built-in keybinds, do not move up!", "Keybinds : 1"
Set-Content "$win64\Mods\FlatOn\Scripts\main.lua" "-- on"
Set-Content "$win64\Mods\FlatOff\Scripts\main.lua" "-- off"
Set-Content "$win64\Mods\Keybinds\Scripts\main.lua" "-- flat keybinds"
"Exit: " + (Run-Patch "--patch")
Check "flat UE4SS moved aside" (-not (Test-Path "$win64\UE4SS.dll") -and -not (Test-Path "$win64\Mods"))
Check "patch's UE4SS installed" ((Select-String -Path "$win64\ue4ss\UE4SS.dll" -Pattern "LoopInGameThreadWithDelay" -SimpleMatch -Quiet))
Check "flat proxy replaced" ((Get-Content "$win64\dwmapi.dll" -Raw) -notmatch "flat proxy")
Check "flat mod that was on adopted and on" ((Test-Path "$fake\Mods\FlatOn\Scripts\main.lua") -and ((Get-Content "$win64\ue4ss\Mods\mods.txt") -contains "FlatOn : 1"))
Check "flat mod that was off adopted and off" ((Test-Path "$fake\Mods\FlatOff\Scripts\main.lua") -and ((Get-Content "$fake\Mods\modlist.txt") -contains "-FlatOff"))
Check "flat UE4SS backed up" ((Get-Content "$fake\Mods\.modloader\ue4ss_before_patch\UE4SS.dll") -eq "flat dll")
"Exit: " + (Run-Patch "--unpatch")
Check "flat UE4SS put back" ((Get-Content "$win64\UE4SS.dll") -eq "flat dll")
Check "flat proxy put back" ((Get-Content "$win64\dwmapi.dll") -eq "flat proxy")
Check "flat settings put back" ((Get-Content "$win64\UE4SS-settings.ini") -eq "flat settings")
Check "flat built-in mods put back" ((Get-Content "$win64\Mods\Keybinds\Scripts\main.lua") -eq "-- flat keybinds")
Check "patch's ue4ss folder removed" (-not (Test-Path "$win64\ue4ss"))
Check "flat backup gone" (-not (Test-Path "$fake\Mods\.modloader\ue4ss_before_patch"))

"--- log"; Get-Content "$fake\Mods\.modloader\modloader.log" | Select-Object -Last 8
"Failures: $script:failures"
