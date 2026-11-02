# Zips installed mods from the game's Mods folder into dist\release, one per mod, for attaching to a GitHub Release.
# Each zip holds the mod's folder, so it unpacks straight into Mods. Leaves out each player's own files.
param(
    [string[]]$Mods = @("AdminPanel", "Backrooms", "BodyVisible", "MonitorSetting"),
    [string]$GameDir = (Split-Path (Split-Path $PSScriptRoot))
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$output = "$PSScriptRoot\dist\release"
$stage = "$PSScriptRoot\build\release_stage"
$personal = "settings.txt", "monitor.txt", "monitors.txt", "helper.log", "enabled.txt"

foreach ($path in $output, $stage) {
    if (Test-Path $path) { Remove-Item $path -Recurse -Force -Confirm:$false }
    New-Item -ItemType Directory -Force $path | Out-Null
}

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
