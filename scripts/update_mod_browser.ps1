# Refreshes docs\mods\mods.json, which the mod browser page reads, from each mod's mod.json and zip in mods\ and from ModKit
# in core\. Version, size, keys, requirements and on/off defaults are filled in here; icon, category, summary and details are
# written by hand in mods.json and kept. A new mod gets a placeholder entry, and a mod whose zip changed is named, so its
# text can be checked. sync_mods.ps1 and make_release_zips.ps1 -InMods run this. -Check only reports whether it is out of date.
# The Mod Manager reads this file too: preset mods (preset) are what the patch installs, and Get Mods lists every mod with a
# zip, compares version with the installed one, and checks each download against sha256.
param([switch]$Check)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = Split-Path $PSScriptRoot  # the repository: this script sits in its scripts folder
$modsDir = "$repo\mods"
$dataPath = "$repo\docs\mods\mods.json"
$utf8 = New-Object System.Text.UTF8Encoding($false)

function ZipManifest($zip) {
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -match '^[^\\/]+[\\/]mod\.json$' } | Select-Object -First 1
        if (-not $entry) { throw "$zip has no mod.json in its folder" }
        $reader = New-Object IO.StreamReader($entry.Open(), $utf8)
        try { $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
}

# Names in a manifest list, with mod folder names shown as titles. The comma keeps a one-item list a list.
function Names($value) {
    $out = @($value | Where-Object { $_ } | ForEach-Object { if ($titles[$_]) { $titles[$_] } else { "$_" } })
    return ,$out
}

# Every mod the site lists: each folder in mods\, each zip in mods\ without a folder, and ModKit.
$found = [ordered]@{}
foreach ($dir in Get-ChildItem $modsDir -Directory | Where-Object { Test-Path "$($_.FullName)\mod.json" }) {
    $found[$dir.Name] = Get-Content "$($dir.FullName)\mod.json" -Raw -Encoding UTF8 | ConvertFrom-Json
}
foreach ($zip in Get-ChildItem $modsDir -Filter *.zip) {
    if (-not $found.Contains($zip.BaseName)) { $found[$zip.BaseName] = ZipManifest $zip.FullName }
}
$found["ModKit"] = Get-Content "$repo\core\ModKit\mod.json" -Raw -Encoding UTF8 | ConvertFrom-Json

$old = @()
if (Test-Path $dataPath) { $old = @((Get-Content $dataPath -Raw -Encoding UTF8 | ConvertFrom-Json).mods) }
$titles = @{}
foreach ($id in $found.Keys) { $titles[$id] = if ($found[$id].title) { $found[$id].title } else { $id } }

# Existing order first, then new mods.
$ids = @($old | ForEach-Object { $_.id } | Where-Object { $found.Contains($_) }) + @($found.Keys | Where-Object { $old.id -notcontains $_ })
$notes = @()
foreach ($gone in $old | Where-Object { -not $found.Contains($_.id) }) { $notes += "$($gone.id) is gone from mods\ and was taken off the site." }

$entries = foreach ($id in $ids) {
    $m = $found[$id]
    $prev = $old | Where-Object { $_.id -eq $id } | Select-Object -First 1
    $zip = Get-Item "$modsDir\$id.zip" -ErrorAction SilentlyContinue
    $sha256 = if ($zip) { (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    $sha = if ($sha256) { $sha256.Substring(0, 12) } else { $null }
    # The Mod Manager installs the zip and compares this version with the installed one, so it comes from the zip.
    $version = if ($zip) { "$((ZipManifest $zip.FullName).version)" } else { "$($m.version)" }
    # "checked" is set by hand to "stamp" once the text is known to fit this build, so the warning repeats until then.
    $stamp = $version + $(if ($sha) { " $sha" } else { "" })
    if (-not $prev) {
        $notes += "$id is new: write its icon, category, summary and details in docs\mods\mods.json, then copy its stamp to checked."
    } elseif ($prev.checked -ne $stamp) {
        $notes += "$id changed since its text was checked: check its summary and details in docs\mods\mods.json, then copy its stamp to checked."
    }
    [ordered]@{
        id         = $id
        title      = $titles[$id]
        icon       = if ($prev) { $prev.icon } else { [char]::ConvertFromUtf32(0x1F9E9) }
        category   = if ($prev) { $prev.category } else { "Tools" }
        summary    = if ($prev) { $prev.summary } else { "$($m.description)" }
        details    = if ($prev) { $prev.details } else { "" }
        checked    = if ($prev) { $prev.checked } else { $null }
        stamp      = $stamp
        version    = $version
        zip        = if ($zip) { $zip.Name } else { $null }
        bytes      = if ($zip) { $zip.Length } else { $null }
        sha        = $sha
        sha256     = $sha256
        keys       = Names $m.keys
        requires   = Names $m.requires
        loadAfter  = Names $m.load_after
        preset     = [bool]($m.preset -or $m.always_on)
        defaultOff = "$($m.enabled_by_default)" -eq "False"
        alwaysOn   = [bool]$m.always_on
    }
}

# Written by hand rather than with ConvertTo-Json, whose layout in Windows PowerShell is hard to edit.
function Json($v) {
    if ($null -eq $v) { return "null" }
    if ($v -is [bool]) { return $(if ($v) { "true" } else { "false" }) }
    if ($v -is [long] -or $v -is [int]) { return $v.ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($v -is [array]) { return "[" + (($v | ForEach-Object { Json $_ }) -join ", ") + "]" }
    $s = "$v".Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $s + '"'
}
$lines = foreach ($e in $entries) {
    $fields = foreach ($k in $e.get_Keys()) { "      " + (Json $k) + ": " + (Json $e[$k]) }
    "    {`n" + ($fields -join ",`n") + "`n    }"
}
$text = "{`n" +
    '  "_note": "Run scripts\\update_mod_browser.ps1 to refresh stamp, version, zip, bytes, sha, sha256, keys, requires, loadAfter, preset, defaultOff and alwaysOn. Edit icon, category, summary and details by hand, then copy stamp to checked. category is one of Scenes, Gameplay, Maps, Visual, Tools.",' + "`n" +
    "  `"mods`": [`n" + ($lines -join ",`n") + "`n  ]`n}`n"

# Line endings are ignored, as git may check the file out with CRLF.
$current = if (Test-Path $dataPath) { [IO.File]::ReadAllText($dataPath, $utf8).Replace("`r`n", "`n") } else { "" }
if ($Check) {
    $notes | ForEach-Object { Write-Warning $_ }
    if ($current -ne $text) { Write-Warning "docs\mods\mods.json is out of date; run scripts\update_mod_browser.ps1."; exit 1 }
    "docs\mods\mods.json is up to date."
    return
}
if ($current -ne $text) { [IO.File]::WriteAllText($dataPath, $text, $utf8); "Updated docs\mods\mods.json." }
else { "docs\mods\mods.json is already up to date." }
$notes | ForEach-Object { Write-Warning $_ }
