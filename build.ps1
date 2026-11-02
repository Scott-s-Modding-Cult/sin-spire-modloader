# Builds dist\SinSpire-ModLoader-Patch.exe, which holds the launcher, UE4SS, ModKit and the preset mods in mods\, and no game files.
#   -GameDir   The Sin Spire folder, used only for the exe's icon. Defaults to two folders above this one.
#   -Ue4ssDir  A folder holding dwmapi.dll and ue4ss\. Defaults to the game's Binaries\Win64.
param(
    [string]$GameDir = (Split-Path (Split-Path $PSScriptRoot)),
    [string]$Ue4ssDir = "$GameDir\SinSpire\Binaries\Win64"
)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$build = "$here\build"
$dist = "$here\dist"
$ue4ssOwnMods = "BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod", "ConsoleCommandsMod", "ConsoleEnablerMod", "Keybinds", "LineTraceMod", "SplitScreenMod"
$references = "/r:System.Windows.Forms.dll", "/r:System.Drawing.dll", "/r:System.Core.dll", "/r:System.Web.Extensions.dll", "/r:System.IO.Compression.dll", "/r:System.IO.Compression.FileSystem.dll"

if (-not (Test-Path "$Ue4ssDir\ue4ss\UE4SS.dll") -or -not (Test-Path "$Ue4ssDir\dwmapi.dll")) {
    throw "UE4SS not found in $Ue4ssDir. Pass -Ue4ssDir with a folder holding dwmapi.dll and ue4ss\UE4SS.dll."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing
if (Test-Path $build) { Remove-Item $build -Recurse -Force }
New-Item -ItemType Directory -Force $build, $dist | Out-Null

# The game's icon is taken from the player's own copy, so it never has to be stored here.
$iconArgument = @()
$iconSource = "$GameDir\SinSpire-Original.exe", "$GameDir\SinSpire.exe" | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($iconSource) {
    $stream = [IO.File]::Create("$build\icon.ico")
    [Drawing.Icon]::ExtractAssociatedIcon($iconSource).Save($stream)
    $stream.Close()
    $iconArgument = @("/win32icon:$build\icon.ico")
}

& $csc /nologo /target:winexe /platform:x64 /optimize+ "/out:$build\launcher.exe" @iconArgument @references "$here\src\Core.cs" "$here\src\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw "Launcher did not compile" }

[IO.Compression.ZipFile]::CreateFromDirectory("$here\core", "$build\modkit.zip")
[IO.Compression.ZipFile]::CreateFromDirectory("$here\mods", "$build\presets.zip")

# UE4SS with only its own mods, leaving out the log and anything of the player's.
$ue4ss = "$build\ue4ss_stage"
New-Item -ItemType Directory -Force "$ue4ss\ue4ss\Mods\shared\UEHelpers" | Out-Null
Copy-Item "$Ue4ssDir\dwmapi.dll" $ue4ss
Get-ChildItem "$Ue4ssDir\ue4ss" -File | Where-Object Name -ne "UE4SS.log" | Copy-Item -Destination "$ue4ss\ue4ss"
if (Test-Path "$Ue4ssDir\ue4ss\UE4SS_SDK_Backends") { Copy-Item "$Ue4ssDir\ue4ss\UE4SS_SDK_Backends" "$ue4ss\ue4ss" -Recurse }
foreach ($name in $ue4ssOwnMods) {
    if (Test-Path "$Ue4ssDir\ue4ss\Mods\$name") { Copy-Item "$Ue4ssDir\ue4ss\Mods\$name" "$ue4ss\ue4ss\Mods" -Recurse }
}
Copy-Item "$Ue4ssDir\ue4ss\Mods\shared\UEHelpers\*" "$ue4ss\ue4ss\Mods\shared\UEHelpers" -Recurse
@"
CheatManagerEnablerMod : 1
ConsoleCommandsMod : 1
ConsoleEnablerMod : 1
SplitScreenMod : 0
LineTraceMod : 0
BPML_GenericFunctions : 1
BPModLoaderMod : 1

; Built-in keybinds, do not move up!
Keybinds : 1
"@ | Set-Content "$ue4ss\ue4ss\Mods\mods.txt" -Encoding ascii
[IO.Compression.ZipFile]::CreateFromDirectory($ue4ss, "$build\ue4ss.zip")

& $csc /nologo /target:winexe /platform:x64 /optimize+ "/out:$dist\SinSpire-ModLoader-Patch.exe" @iconArgument @references "/resource:$build\launcher.exe,launcher.exe" "/resource:$build\ue4ss.zip,ue4ss.zip" "/resource:$build\modkit.zip,modkit.zip" "/resource:$build\presets.zip,presets.zip" "$here\src\Core.cs" "$here\src\Patcher.cs"
if ($LASTEXITCODE -ne 0) { throw "Patch did not compile" }
Get-Item "$dist\SinSpire-ModLoader-Patch.exe" | Select-Object Name, Length
