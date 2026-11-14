# Zips installed mods from the game's Mods folder, one per mod, into dist\release for attaching to a GitHub Release.
# Each zip holds the mod's folder, so it unpacks straight into Mods. Leaves out each player's own files.
# -InMods puts the zips in mods\ instead, ready to commit. Unless -Mods names some, that is every mod in mods\ and Backrooms,
# whose folder is too big for this repository but whose zip is not, and the mod browser's data in docs\mods\mods.json is
# refreshed. Run sync_mods.ps1 first.
param(
    [string[]]$Mods = @("AdminPanel", "Backrooms", "BodyVisible", "MonitorSetting"),
    [string]$GameDir = (Split-Path (Split-Path $PSScriptRoot)),
    [switch]$InMods
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$output = "$PSScriptRoot\dist\release"
if ($InMods) {
    $output = "$PSScriptRoot\mods"
    if (-not $PSBoundParameters.ContainsKey("Mods")) {
        $Mods = @(Get-ChildItem $output -Directory | ForEach-Object { $_.Name }) + "Backrooms"
    }
}
$stage = "$PSScriptRoot\build\release_stage"
$personal = "settings.txt", "monitor.txt", "monitors.txt", "helper.log", "enabled.txt", "mod-randomizer.json", "boss-timer.txt", "controller-debug.log"

# Only the zips being remade are cleared, as mods\ also holds the mods themselves.
foreach ($mod in $Mods) {
    if (Test-Path "$output\$mod.zip") { Remove-Item "$output\$mod.zip" -Force -Confirm:$false }
}
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Force $output, $stage | Out-Null

foreach ($mod in $Mods) {
    $from = "$GameDir\Mods\$mod"
    if (-not (Test-Path "$from\mod.json")) { throw "$mod is not installed" }
    $to = "$stage\$mod"
    foreach ($file in Get-ChildItem $from -Recurse -File | Where-Object { $personal -notcontains $_.Name }) {
        $path = Join-Path $to $file.FullName.Substring($from.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
        Copy-Item $file.FullName $path
    }
    [IO.Compression.ZipFile]::CreateFromDirectory($to, "$output\$mod.zip", [IO.Compression.CompressionLevel]::Optimal, $true)
}
Remove-Item $stage -Recurse -Force -Confirm:$false
Get-ChildItem $output | Select-Object Name, Length
if ($InMods) { & "$PSScriptRoot\update_mod_browser.ps1" }
