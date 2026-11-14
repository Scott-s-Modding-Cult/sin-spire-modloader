# The launcher's self-update on a fake game folder, against a releases list in a local file instead of GitHub.
#   -NewerPatch  A patch built with build.ps1 -Tag patch-2099.01.01, which the list offers as the newest release.
# No real game files are touched.
param([Parameter(Mandatory)][string]$NewerPatch)
$ErrorActionPreference = "Stop"
$scratch = Join-Path $env:TEMP "sinspire_update_test"
if (Test-Path $scratch) { cmd /c rmdir /s /q "`"$scratch`"" }
New-Item -ItemType Directory -Force $scratch | Out-Null
$patch = "$PSScriptRoot\..\dist\SinSpire-ModLoader-Patch.exe"
$fake = "$scratch\fake game"
$script:failures = 0
function Check($name, $ok) { if ($ok) { "ok    $name" } else { "FAIL  $name"; $script:failures++ } }
function Installed { ((Get-Content "$fake\Mods\.modloader\install.txt") | Where-Object { $_ -like "patch=*" }) -replace "^patch=", "" }
function Cached($key) { ((Get-Content "$fake\Mods\.modloader\update.txt") | Where-Object { $_ -like "$key=*" }) -replace "^$key=", "" }
# Starts SinSpire.exe and waits for the fake game to write launched.txt. True when it started in time.
function Launch($answer, $seconds = 15) {
    Remove-Item "$fake\launched.txt" -ErrorAction SilentlyContinue
    $env:SINSPIRE_MODLOADER_TEST_ANSWER = $answer
    $launcher = Start-Process "$fake\SinSpire.exe" -ArgumentList "-testarg" -PassThru
    for ($i = 0; $i -lt $seconds * 10 -and -not (Test-Path "$fake\launched.txt"); $i++) { Start-Sleep -Milliseconds 100 }
    $launcher.WaitForExit(15000) | Out-Null
    Test-Path "$fake\launched.txt"
}

# A fake game, patched with this build.
$win64 = "$fake\SinSpire\Binaries\Win64"
New-Item -ItemType Directory -Force $win64, "$fake\SinSpire\Content\Paks" | Out-Null
Set-Content "$scratch\fake.cs" 'class P { static void Main(string[] a) { System.IO.File.WriteAllText(System.AppDomain.CurrentDomain.BaseDirectory + "launched.txt", string.Join(" ", a)); } }'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe "/out:$fake\SinSpire.exe" "$scratch\fake.cs"
Set-Content "$win64\SinSpire-Win64-Shipping.exe" "fake"
(Start-Process $patch -ArgumentList "--patch", "`"$fake`"" -Wait -PassThru).ExitCode | Out-Null
$ours = Installed
Check "patch records its release ($ours)" ($ours -match '^patch-\d{4}\.\d{2}\.\d{2}')

# The releases list: a newer mod release and a test pre-release come first and must be passed over.
Copy-Item $NewerPatch "$scratch\SinSpire-ModLoader-Patch.exe"
$newer = Get-Item "$scratch\SinSpire-ModLoader-Patch.exe"
$newerTag = "patch-2099.01.01"
$asset = @{ name = "SinSpire-ModLoader-Patch.exe"; size = $newer.Length; browser_download_url = ([Uri]$newer.FullName).AbsoluteUri; digest = "sha256:" + (Get-FileHash $newer.FullName).Hash.ToLower() }
$list = @(
    @{ tag_name = "gooner-dlc-9.9.9"; name = "Gooner DLC"; draft = $false; prerelease = $false; assets = @(@{ name = "GoonerDLC.zip"; size = 1; browser_download_url = "file:///none"; digest = "sha256:00" }) },
    @{ tag_name = "patch-2099.02.02-test"; name = "testing"; draft = $false; prerelease = $true; assets = @($asset) },
    @{ tag_name = $newerTag; name = "Stand-in"; draft = $false; prerelease = $false; assets = @($asset) }
)
ConvertTo-Json -InputObject $list -Depth 6 | Set-Content "$scratch\releases.json" -Encoding ascii
$env:SINSPIRE_MODLOADER_TEST_API = ([Uri]"$scratch\releases.json").AbsoluteUri
$env:TEMP = "$scratch\temp"; $env:TMP = $env:TEMP; New-Item -ItemType Directory -Force $env:TEMP | Out-Null

Check "first start runs the game" (Launch "")
Check "after it, the newest patch release is remembered" ((Cached "tag") -eq $newerTag)
Check "not now: the game starts, nothing changes" ((Launch "later") -and (Installed) -eq $ours)
Check "skip: the game starts" (Launch "skip")
Check "skip is remembered" ((Cached "skip") -eq $newerTag)
Check "a skipped version is not offered again (no prompt to wait on)" (Launch "")
Set-Content "$fake\Mods\.modloader\update.txt" (Get-Content "$fake\Mods\.modloader\update.txt" | Where-Object { $_ -notlike "skip=*" })

# Update: the launcher downloads and checks the patch, hands over and closes; the patch updates and starts it again.
Check "update: the game starts again afterwards" (Launch "update" 90)
Check "update installed the newer patch's release" ((Installed) -eq $newerTag)
Check "the game got its arguments back" ((Get-Content "$fake\launched.txt") -match "-testarg")
Check "SinSpire.exe is still the launcher" ((Get-Item "$fake\SinSpire.exe").VersionInfo.ProductName -eq "SinSpire Mod Loader")
Check "the game's own exe is still kept" (Test-Path "$fake\SinSpire-Original.exe")
Check "the update has its own log" ((Get-Content "$fake\Mods\.modloader\update.log" -Raw) -match "Updating the mod loader to $newerTag")
Check "nothing offered after updating" ($null -eq (Get-Content "$fake\Mods\.modloader\update.txt" | Where-Object { $_ -like "tag=*" } | Where-Object { [string]::CompareOrdinal(($_ -replace '^tag=', ''), (Installed)) -gt 0 }))

"--- log"; Get-Content "$fake\Mods\.modloader\modloader.log" | Select-Object -Last 10
"Failures: $script:failures"
