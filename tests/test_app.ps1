# The Sin Spire Mod Manager as an app, on a fake game folder: installing through the Mod Loader tab, the update offer,
# removing and installing again through the copy that takes over from the game's own SinSpire.exe, and an update that
# replaces the downloaded app. The mod list, releases and Start menu are stand-ins in the test folder; nothing is
# started and no real game files are touched. Build first, with scripts\build.ps1.
#   -NewerApp  A Mod Manager built with scripts\build.ps1 -Tag patch-2099.01.01.
param([Parameter(Mandatory)][string]$NewerApp)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$scratch = Join-Path $env:TEMP "sinspire_app_test"
if (Test-Path $scratch) { cmd /c rmdir /s /q "`"$scratch`"" }
$fake = "$scratch\fake game"
$script:failures = 0
function Check($name, $ok) { if ($ok) { "ok    $name" } else { "FAIL  $name"; $script:failures++ } }
function Hash($file) { (Get-FileHash $file).Hash }

$repo = Split-Path $PSScriptRoot
New-Item -ItemType Directory -Force "$scratch\app", "$scratch\temp", "$scratch\startmenu", "$fake\SinSpire\Binaries\Win64", "$fake\SinSpire\Content\Paks" | Out-Null
$env:TEMP = "$scratch\temp"; $env:TMP = $env:TEMP
$env:SINSPIRE_MODLOADER_TEST_MODS = ([Uri]"$repo\docs\mods\mods.json").AbsoluteUri
$env:SINSPIRE_MODLOADER_TEST_ZIPS = ([Uri]"$repo\mods\").AbsoluteUri
$env:SINSPIRE_MODLOADER_TEST_SHORTCUTS = "$scratch\startmenu"
$env:SINSPIRE_MODLOADER_TEST_NO_START = "$scratch\started.txt"
Copy-Item $NewerApp "$scratch\newer.exe"
$asset = @{ name = "SinSpire-ModManager.exe"; size = (Get-Item "$scratch\newer.exe").Length; browser_download_url = ([Uri]"$scratch\newer.exe").AbsoluteUri; digest = "sha256:" + (Hash "$scratch\newer.exe").ToLower() }
ConvertTo-Json -InputObject @(@{ tag_name = "patch-2099.01.01"; name = "Stand-in"; draft = $false; prerelease = $false; assets = @($asset) }) -Depth 6 | Set-Content "$scratch\releases.json" -Encoding ascii
$env:SINSPIRE_MODLOADER_TEST_API = ([Uri]"$scratch\releases.json").AbsoluteUri

# The fake game, and the app as downloaded.
Set-Content "$scratch\fake.cs" 'class P { static void Main(string[] a) { System.IO.File.WriteAllText(System.AppDomain.CurrentDomain.BaseDirectory + "launched.txt", string.Join(" ", a)); } }'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe "/out:$fake\SinSpire.exe" "$scratch\fake.cs"
Set-Content "$fake\SinSpire\Binaries\Win64\SinSpire-Win64-Shipping.exe" "fake"
$gameExe = Hash "$fake\SinSpire.exe"
$app = "$scratch\app\SinSpire-ModManager.exe"
Copy-Item "$repo\dist\SinSpire-ModManager.exe" $app
$appHash = Hash $app

# --- The app's window, through its own code: it opens on the Mod Loader tab and installs from there.
$assembly = [Reflection.Assembly]::LoadFile($app)
$game = [Activator]::CreateInstance($assembly.GetType("SinSpireModLoader.GameFolder"), [object[]]@($fake))
$form = [Activator]::CreateInstance($assembly.GetType("SinSpireModLoader.ManagerForm"), [object[]]@($game, $true))
$form.StartPosition = "Manual"; $form.Location = New-Object Drawing.Point(-3000, -3000); $form.ShowInTaskbar = $false
function Field($name) { $form.GetType().GetField($name, [Reflection.BindingFlags]"NonPublic,Instance").GetValue($form) }
function Pump($seconds) { for ($i = 0; $i -lt $seconds * 20; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 } }
function Find-Control($parent, $type) {
    foreach ($child in $parent.Controls) { if ($child -is $type) { return $child }; $found = Find-Control $child $type; if ($found) { return $found } }
}
$form.Show()
Pump 3
$tabs = Find-Control $form ([Windows.Forms.TabControl])
Check "app opens on the Mod Loader tab" ($tabs.SelectedTab.Text -eq "Mod Loader")
Check "says the loader isn't installed" ((Field "loaderState").Text -match "not installed")
Check "offers Install Mod Loader" ((Field "installLoader").Visible -and (Field "installLoader").Enabled)
Check "offers the newer version" ((Field "updateLoader").Visible -and (Field "loaderState").Text -match "patch-2099\.01\.01")
Check "Save and Play off until installed" (-not (Field "play").Enabled)
(Field "installLoader").PerformClick()
for ($i = 0; $i -lt 120 -and -not ((Field "removeLoader").Visible); $i++) { Pump 0.5 }
Check "Install puts the app in as the game's SinSpire.exe" ((Hash "$fake\SinSpire.exe") -eq $appHash)
Check "the game's own exe is kept" ((Hash "$fake\SinSpire-Original.exe") -eq $gameExe)
Check "UE4SS and ModKit in" ((Test-Path "$fake\SinSpire\Binaries\Win64\ue4ss\UE4SS.dll") -and (Test-Path "$fake\Mods\ModKit\mod.json"))
Check "preset mods in" (Test-Path "$fake\Mods\AdminPanel\mod.json")
Check "Start menu entry added" (Test-Path "$scratch\startmenu\Sin Spire Mod Manager.lnk")
Check "tab now offers Repair and Remove" ((Field "repairLoader").Visible -and (Field "removeLoader").Visible -and -not (Field "installLoader").Visible)
Check "Mods tab lists the mods" ((Find-Control $tabs.TabPages[0] ([Windows.Forms.CheckedListBox])).Items.Count -ge 5)
Check "Save and Play on" ((Field "play").Enabled)
Check "install written to the log box" ((Field "loaderLog").Text -match "Installed the mod loader as SinSpire.exe")
$form.Close(); $form.Dispose()
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut("$scratch\startmenu\Sin Spire Mod Manager.lnk")
Check "Start menu entry opens the Mod Manager from the game" ($link.TargetPath -eq "$fake\SinSpire.exe" -and $link.Arguments -eq "-modmanager")

# --- From the game's own copy, removing is handed to a copy of itself, as SinSpire.exe can't delete itself.
# As App.HandOver does: the game's copy copies itself to the temp folder and starts that copy with the job.
Copy-Item "$fake\SinSpire.exe" "$scratch\temp\SinSpire-ModManager-handover.exe"
$code = (Start-Process "$scratch\temp\SinSpire-ModManager-handover.exe" -ArgumentList "--handover", "remove", "`"$fake`"", "--wait", "0" -Wait -PassThru).ExitCode
Check "remove through the hand-over (exit 0)" ($code -eq 0)
Check "game's own exe back" ((Hash "$fake\SinSpire.exe") -eq $gameExe -and -not (Test-Path "$fake\SinSpire-Original.exe"))
Check "Start menu entry removed" (-not (Test-Path "$scratch\startmenu\Sin Spire Mod Manager.lnk"))
Check "mods kept" (Test-Path "$fake\Mods\AdminPanel\mod.json")
$code = (Start-Process "$scratch\temp\SinSpire-ModManager-handover.exe" -ArgumentList "--handover", "install", "`"$fake`"", "--wait", "0", "--shortcut" -Wait -PassThru).ExitCode
Check "install through the hand-over (exit 0)" ($code -eq 0 -and (Hash "$fake\SinSpire.exe") -eq $appHash -and (Test-Path "$scratch\startmenu\Sin Spire Mod Manager.lnk"))
Check "then the Mod Manager opens from the game" ((Get-Content "$scratch\started.txt" -Raw) -match [regex]::Escape("$fake\SinSpire.exe") + " -modmanager")

# --- An update replaces both the game's copy and the downloaded app, then opens the app again. (A second copy of the
# app, as this test has the first one loaded.)
Remove-Item "$scratch\started.txt"
New-Item -ItemType Directory -Force "$scratch\downloads" | Out-Null
$app = "$scratch\downloads\SinSpire-ModManager.exe"
Copy-Item "$repo\dist\SinSpire-ModManager.exe" $app
$code = (Start-Process "$scratch\newer.exe" -ArgumentList "--update", "`"$fake`"", "--wait", "0", "--app", "`"$app`"" -Wait -PassThru).ExitCode
$newerHash = Hash "$scratch\newer.exe"
Check "update (exit 0)" ($code -eq 0)
Check "game's SinSpire.exe is the new version" ((Hash "$fake\SinSpire.exe") -eq $newerHash)
Check "downloaded app replaced by the new version" ((Hash $app) -eq $newerHash)
Check "game records the new version" ((Get-Content "$fake\Mods\.modloader\install.txt") -contains "patch=patch-2099.01.01")
Check "then the app opens again" ((Get-Content "$scratch\started.txt" -Raw) -match [regex]::Escape($app))
Check "update logged" ((Get-Content "$fake\Mods\.modloader\update.log" -Raw) -match "Updated SinSpire-ModManager.exe")

# --- The game's copy is the launcher: it starts the game.
Remove-Item "$fake\launched.txt" -ErrorAction SilentlyContinue
Start-Process "$fake\SinSpire.exe" -ArgumentList "-testarg" -Wait
for ($i = 0; $i -lt 50 -and -not (Test-Path "$fake\launched.txt"); $i++) { Start-Sleep -Milliseconds 100 }
Check "the game's copy starts the game" ((Get-Content "$fake\launched.txt") -match "-testarg")

"Failures: $script:failures"
