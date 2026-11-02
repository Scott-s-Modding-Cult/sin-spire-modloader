# Copies the installed mods from the game's Mods folder into mods\ here, ready to build and commit.
# Leaves out each player's own files, ModKit, whose source is in core\, and mods too big for this repository, which are on
# the Releases page instead.
param([string]$GameDir = (Split-Path (Split-Path $PSScriptRoot)))
$ErrorActionPreference = "Stop"
$target = "$PSScriptRoot\mods"
$personal = "settings.txt", "monitor.txt", "monitors.txt", "helper.log", "enabled.txt", "mod-randomizer.json"

foreach ($mod in Get-ChildItem "$GameDir\Mods" -Directory | Where-Object { $_.Name -notlike ".*" -and $_.Name -ne "ModKit" -and $_.Name -ne "Backrooms" }) {
    $to = "$target\$($mod.Name)"
    if (Test-Path $to) { Remove-Item $to -Recurse -Force }
    foreach ($file in Get-ChildItem $mod.FullName -Recurse -File | Where-Object { $personal -notcontains $_.Name }) {
        $path = Join-Path $to $file.FullName.Substring($mod.FullName.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
        Copy-Item $file.FullName $path
    }
    $mod.Name
}
