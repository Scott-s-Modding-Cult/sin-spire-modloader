# Exercises the Mod Manager's Get Mods tab on a fake game folder, including a real download from GitHub. Build first.
# Run with powershell -STA, as it opens the window off screen. -Picture saves what the tab looks like.
param([string]$Picture)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$scratch = Join-Path $env:TEMP "sinspire_import_test"
$fake = "$scratch\fake game"
$script:failures = 0
function Check($name, $ok) { if ($ok) { "ok    $name" } else { "FAIL  $name"; $script:failures++ } }

if (Test-Path $scratch) { cmd /c rmdir /s /q "`"$scratch`"" }
New-Item -ItemType Directory -Force "$fake\SinSpire\Binaries\Win64", "$fake\SinSpire\Content\Paks", "$fake\Mods" | Out-Null
Set-Content "$fake\SinSpire\Binaries\Win64\SinSpire-Win64-Shipping.exe" "fake"

# The classes are internal, so they are reached through reflection.
$launcher = [Reflection.Assembly]::LoadFile((Resolve-Path "$PSScriptRoot\..\build\launcher.exe").Path)
$importer = $launcher.GetType("SinSpireModLoader.Importer")
$game = [Activator]::CreateInstance($launcher.GetType("SinSpireModLoader.GameFolder"), [object[]]@($fake))
function Call($method) { $importer.GetMethod($method).Invoke($null, [object[]]@($args | ForEach-Object { $_.PSObject.BaseObject })) }
function Install-Zip($name, $zip) {
    try { Call "InstallZip" $game $name $zip; $true } catch { $false }
}
function Make-Zip($path, $entries) {
    $archive = [IO.Compression.ZipFile]::Open($path, "Create")
    foreach ($entry in $entries) {
        $writer = New-Object IO.StreamWriter($archive.CreateEntry($entry).Open())
        $writer.Write("new")
        $writer.Dispose()
    }
    $archive.Dispose()
}

# --- An update replaces the folder, keeps the player's files, and saves the old version.
$mod = "$fake\Mods\Thing"
New-Item -ItemType Directory -Force "$mod\Scripts" | Out-Null
Set-Content "$mod\mod.json" "old"
Set-Content "$mod\Scripts\main.lua" "old"
Set-Content "$mod\Scripts\removed.lua" "old"
Set-Content "$mod\settings.txt" "keep=1"
Set-Content "$mod\mod-randomizer.json" "keep=2"
Set-Content "$mod\boss-timer.txt" "off"
Make-Zip "$scratch\Thing.zip" @("Thing/mod.json", "Thing/Scripts/main.lua")
Check "update installs" (Install-Zip "Thing" "$scratch\Thing.zip")
Check "new file in place" ((Get-Content "$mod\Scripts\main.lua") -eq "new")
Check "file no longer in the mod is gone" (-not (Test-Path "$mod\Scripts\removed.lua"))
Check "settings kept" ((Get-Content "$mod\settings.txt") -eq "keep=1")
Check "randomizer settings kept" ((Get-Content "$mod\mod-randomizer.json") -eq "keep=2")
Check "boss timer setting kept" ((Get-Content "$mod\boss-timer.txt") -eq "off")
Check "old version backed up" ((Get-Content "$fake\Mods\.modloader\backup\Thing\Scripts\main.lua") -eq "old")
Check "import folder cleaned" (-not (Test-Path "$fake\Mods\.modloader\import\Thing"))

# --- A bad zip leaves the installed mod alone.
Make-Zip "$scratch\Slip.zip" @("Thing/mod.json", "Thing/../../../evil.txt")
Check "zip escaping its folder refused" (-not (Install-Zip "Thing" "$scratch\Slip.zip"))
Check "nothing written outside" (-not (Test-Path "$fake\Mods\evil.txt") -and -not (Test-Path "$fake\evil.txt"))
Make-Zip "$scratch\Other.zip" @("Other/mod.json")
Check "zip of another mod refused" (-not (Install-Zip "Thing" "$scratch\Other.zip"))
Make-Zip "$scratch\NoManifest.zip" @("Thing/Scripts/main.lua")
Check "zip with no mod.json refused" (-not (Install-Zip "Thing" "$scratch\NoManifest.zip"))
Check "installed mod untouched" ((Get-Content "$mod\mod.json") -eq "new")

# --- The real list and a real download, including the hash check.
$list = Call "List"
Check "repository lists mods" ($list.Count -gt 0)
$small = $list | Sort-Object Size | Select-Object -First 1
Call "Install" $game $small
Check "downloaded mod installed" (Test-Path "$fake\Mods\$($small.Name)\mod.json")
Check "download recorded" ((Call "Recorded" $game)[$small.Name] -eq $small.Sha)
$broken = [Activator]::CreateInstance($small.GetType())
$broken.Name = $small.Name; $broken.Url = $small.Url; $broken.Size = $small.Size; $broken.Sha = "0000"
$refused = $false
try { Call "Install" $game $broken } catch { $refused = $true }
Check "damaged download refused" $refused

# --- The window: the tab fills in by itself, and installing works through its buttons.
$form = [Activator]::CreateInstance($launcher.GetType("SinSpireModLoader.ManagerForm"), [object[]]@($game))
$form.StartPosition = "Manual"
$form.Location = New-Object Drawing.Point(-3000, -3000)
$form.Show()
function Find-Control($parent, $type) {
    foreach ($child in $parent.Controls) {
        if ($child -is $type) { return $child }
        $found = Find-Control $child $type
        if ($found) { return $found }
    }
}
function Pump($seconds) { for ($i = 0; $i -lt $seconds * 20; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 } }
$tabs = Find-Control $form ([Windows.Forms.TabControl])
$tabs.SelectedIndex = 1
Pump 5
$rows = Find-Control $tabs.TabPages[1] ([Windows.Forms.ListView])
Check "tab lists the mods" ($rows.Items.Count -eq $list.Count)
$row = $rows.Items | Where-Object { $_.Tag.Name -eq $small.Name }
Check "downloaded mod shows up to date" ($row.SubItems[3].Text -eq "Up to date")
$row.Selected = $true
[Windows.Forms.Application]::DoEvents()
$other = $rows.Items | Where-Object { $_.SubItems[3].Text -eq "Not installed" } | Sort-Object { $_.Tag.Size } | Select-Object -First 1
Check "other mods show not installed" ($null -ne $other)
$other.Selected = $true
[Windows.Forms.Application]::DoEvents()
$button = $tabs.TabPages[1].Controls[0].Controls | ForEach-Object { $_.Controls } | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq "Install" }
Check "button offers install" ($null -ne $button)
$name = $other.Tag.Name
$button.PerformClick()
Pump 6
Check "button installs the mod" (Test-Path "$fake\Mods\$name\mod.json")
$row = $rows.Items | Where-Object { $_.Tag.Name -eq $name }
Check "row now shows up to date" ($row.SubItems[3].Text -eq "Up to date")
Check "button now offers reinstall" ($button.Text -eq "Reinstall")
$checks = Find-Control $tabs.TabPages[0] ([Windows.Forms.CheckedListBox])
Check "mods tab shows the new mod" ($checks.Items.Count -ge 3)
if ($Picture) {
    $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bitmap.Save($Picture)
}
$form.Close()
$form.Dispose()

"Failures: $script:failures"
