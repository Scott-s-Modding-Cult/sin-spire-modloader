# Builds dist\SinSpire-ModLoader-Patch.exe, which holds the launcher, UE4SS, ModKit and the preset mods in mods\, and no game files.
#   -GameDir   The Sin Spire folder, used only for the exe's icon. Found by itself if left out.
#   -Ue4ssDir  A folder holding dwmapi.dll and ue4ss\. Found in a game folder or in ue4ss_files\ here if left out.
#   -Pick      Asks with a folder window when UE4SS cannot be found. Build Patch.bat uses this.
param(
    [string]$GameDir,
    [string]$Ue4ssDir,
    [switch]$Pick
)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot

function Test-Game($folder) { $folder -and (Test-Path "$folder\SinSpire\Binaries\Win64\SinSpire-Win64-Shipping.exe") }
function Test-Ue4ss($folder) { $folder -and (Test-Path "$folder\ue4ss\UE4SS.dll") -and (Test-Path "$folder\dwmapi.dll") }

# The folder two above this one when this is kept inside a game's _modtools, then every Steam library with the game.
function Find-Games {
    Split-Path (Split-Path $here)
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        Join-Path $steam "steamapps\common\Sin Spire"
        $libraries = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $libraries) {
            foreach ($match in [regex]::Matches((Get-Content $libraries -Raw), '"path"\s+"([^"]+)"')) {
                Join-Path $match.Groups[1].Value.Replace('\\', '\') "steamapps\common\Sin Spire"
            }
        }
    }
}

$games = @(Find-Games | Where-Object { Test-Game $_ })
if (-not $GameDir -and $games.Count -gt 0) { $GameDir = $games[0] }
if (-not $Ue4ssDir) {
    $candidates = @("$here\ue4ss_files") + @($games | ForEach-Object { "$_\SinSpire\Binaries\Win64" })
    $Ue4ssDir = $candidates | Where-Object { Test-Ue4ss $_ } | Select-Object -First 1
}
if (-not $Ue4ssDir -and $Pick) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "UE4SS was not found. Choose the folder holding dwmapi.dll and the ue4ss folder."
    if ($dialog.ShowDialog() -eq "OK") { $Ue4ssDir = $dialog.SelectedPath }
}
"Game folder: $(if ($GameDir) { $GameDir } else { 'not found, so the patch will have no icon' })"
"UE4SS from:  $Ue4ssDir"

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$build = "$here\build"
$dist = "$here\dist"
$ue4ssOwnMods = "BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod", "ConsoleCommandsMod", "ConsoleEnablerMod", "Keybinds", "LineTraceMod", "SplitScreenMod"
$references = "/r:System.Windows.Forms.dll", "/r:System.Drawing.dll", "/r:System.Core.dll", "/r:System.Web.Extensions.dll", "/r:System.IO.Compression.dll", "/r:System.IO.Compression.FileSystem.dll"

if (-not (Test-Ue4ss $Ue4ssDir)) {
    throw "UE4SS was not found. Put dwmapi.dll and the ue4ss folder in ue4ss_files here, or pass -Ue4ssDir with a folder holding them."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing
if (Test-Path $build) { Remove-Item $build -Recurse -Force }
New-Item -ItemType Directory -Force $build, $dist | Out-Null

# The game's icon is taken from the player's own copy, so it never has to be stored here.
$iconArgument = @()
$iconSource = if ($GameDir) { "$GameDir\SinSpire-Original.exe", "$GameDir\SinSpire.exe" | Where-Object { Test-Path $_ } | Select-Object -First 1 }
if ($iconSource) {
    $stream = [IO.File]::Create("$build\icon.ico")
    [Drawing.Icon]::ExtractAssociatedIcon($iconSource).Save($stream)
    $stream.Close()
    $iconArgument = @("/win32icon:$build\icon.ico")
}

& $csc /nologo /target:winexe /platform:x64 /optimize+ "/out:$build\launcher.exe" @iconArgument @references "$here\src\Core.cs" "$here\src\Importer.cs" "$here\src\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw "Launcher did not compile" }

[IO.Compression.ZipFile]::CreateFromDirectory("$here\core", "$build\modkit.zip")
[IO.Compression.ZipFile]::CreateFromDirectory("$here\mods", "$build\presets.zip")
# The credits travel with the assets they cover, so they land in the player's Mods folder too.
$presets = [IO.Compression.ZipFile]::Open("$build\presets.zip", "Update")
# The mod zips in mods\ are for downloading on their own, and the patch already holds what is in them.
@($presets.Entries | Where-Object { $_.FullName -like "*.zip" }) | ForEach-Object { $_.Delete() }
[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($presets, "$here\CREDITS.txt", "CREDITS.txt")
$presets.Dispose()

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

& $csc /nologo /target:winexe /platform:x64 /optimize+ "/out:$dist\SinSpire-ModLoader-Patch.exe" @iconArgument @references "/resource:$build\launcher.exe,launcher.exe" "/resource:$build\ue4ss.zip,ue4ss.zip" "/resource:$build\modkit.zip,modkit.zip" "/resource:$build\presets.zip,presets.zip" "$here\src\Core.cs" "$here\src\GameSearch.cs" "$here\src\Patcher.cs"
if ($LASTEXITCODE -ne 0) { throw "Patch did not compile" }
Get-Item "$dist\SinSpire-ModLoader-Patch.exe" | Select-Object Name, Length
