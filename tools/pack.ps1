<#
  pack.ps1 - build a flashable zip from this module tree.

  Usage:
    powershell -ExecutionPolicy Bypass -File tools\pack.ps1
    powershell -ExecutionPolicy Bypass -File tools\pack.ps1 -ModuleId my_module
    powershell -ExecutionPolicy Bypass -File tools\pack.ps1 -ModuleId x -ModuleName "LSPosed Stealth" -OutputDir D:\out

  The module id ends up in two places: module.prop and webroot/app.js.
  Everything else derives its paths at runtime from module.prop, so nothing
  else needs rewriting.
#>
param(
  [string]$ModuleId   = '',
  [string]$ModuleName = '',
  [string]$OutputDir  = '',
  [switch]$NoZip
)

$ErrorActionPreference = 'Stop'

$ModuleRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path -Parent $ModuleRoot) 'dist' }

# ---------- required files ----------
$required = @(
  'module.prop',
  'customize.sh',
  'post-fs-data.sh',
  'service.sh',
  'boot-completed.sh',
  'uninstall.sh',
  'sepolicy.rule',
  'system.prop',
  'common/env.sh',
  'common/targets.sh',
  'common/audit.sh',
  'common/scrub.sh',
  'common/mute.sh',
  'common/conf.sh',
  'common/daemon.sh',
  'common/known.json',
  'common/upstream.sh',
  'common/autoconfig.sh',
  'common/hma.sh',
  'common/migrate.sh',
  'webroot/index.html',
  'webroot/style.css',
  'webroot/app.js'
)

$missing = @()
foreach ($rel in $required) {
  if (-not (Test-Path (Join-Path $ModuleRoot $rel))) { $missing += $rel }
}
if ($missing.Count -gt 0) {
  Write-Host 'MISSING REQUIRED FILES:' -ForegroundColor Red
  $missing | ForEach-Object { Write-Host "  $_" }
  exit 1
}
Write-Host "[ok] all $($required.Count) required files present"

# ---------- resolve module id ----------
$propPath = Join-Path $ModuleRoot 'module.prop'
$propText = [System.IO.File]::ReadAllText($propPath)

$currentId = ''
foreach ($line in ($propText -split "`n")) {
  if ($line -match '^\s*id\s*=\s*(.+)$') { $currentId = $Matches[1].Trim(); break }
}
if (-not $ModuleId) { $ModuleId = $currentId }

if ($ModuleId -notmatch '^[a-zA-Z][a-zA-Z0-9._-]*$') {
  Write-Host "invalid module id: '$ModuleId' (must start with a letter, only letters digits . _ -)" -ForegroundColor Red
  exit 1
}
Write-Host "[ok] module id: $ModuleId"

$version = 'v1.0.0'
foreach ($line in ($propText -split "`n")) {
  if ($line -match '^\s*version\s*=\s*(.+)$') { $version = $Matches[1].Trim(); break }
}

# ---------- stage ----------
if (Test-Path $OutputDir) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
else { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("mcp-stage-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$skip = @('tools', 'dist', 'release', '.git', '.cyrene', '.gitattributes', '.gitignore', 'LICENSE', 'README.md')
Get-ChildItem -Path $ModuleRoot -Force | Where-Object { $skip -notcontains $_.Name } | ForEach-Object {
  Copy-Item -Path $_.FullName -Destination $stage -Recurse -Force
}
Write-Host "[ok] staged to $stage"

# ---------- rewrite id / name ----------
$stagedProp = Join-Path $stage 'module.prop'
$lines = [System.IO.File]::ReadAllText($stagedProp) -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$out = New-Object System.Collections.Generic.List[string]

foreach ($line in $lines) {
  if ($line -match '^\s*id\s*=') {
    $out.Add("id=$ModuleId")
  } elseif ($ModuleName -and $line -match '^\s*name\s*=') {
    $out.Add("name=$ModuleName")
  } else {
    $out.Add($line)
  }
}
[System.IO.File]::WriteAllText($stagedProp, ($out -join "`n"), (New-Object System.Text.UTF8Encoding($false)))

$appJs = Join-Path $stage 'webroot/app.js'
$js = [System.IO.File]::ReadAllText($appJs)
$js = [regex]::Replace($js, "var MODULE_ID = '[^']*';", "var MODULE_ID = '$ModuleId';", 1)
[System.IO.File]::WriteAllText($appJs, $js, (New-Object System.Text.UTF8Encoding($false)))

# verify the rewrite actually landed
$check = [System.IO.File]::ReadAllText($appJs)
if ($check -notmatch [regex]::Escape("var MODULE_ID = '$ModuleId';")) {
  Write-Host 'failed to rewrite MODULE_ID in webroot/app.js' -ForegroundColor Red
  exit 1
}
Write-Host "[ok] rewrote module id in module.prop and webroot/app.js"

# ---------- line ending check ----------
# Android /system/bin/sh chokes on CRLF. Every shipped script must be LF only.
$bad = @()
Get-ChildItem -Path $stage -Recurse -File -Include *.sh | ForEach-Object {
  $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
  for ($i = 1; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -eq 10 -and $bytes[$i - 1] -eq 13) { $bad += $_.FullName; break }
  }
}
if ($bad.Count -gt 0) {
  Write-Host 'CRLF FOUND IN SHELL SCRIPTS:' -ForegroundColor Red
  $bad | ForEach-Object { Write-Host "  $_" }
  Remove-Item $stage -Recurse -Force
  exit 1
}
Write-Host '[ok] all shell scripts use LF endings'

# ---------- zip ----------
if ($NoZip) {
  Write-Host "[done] staged tree left at $stage"
  exit 0
}

$zipName = "$ModuleId-$version.zip"
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Do NOT use [ZipFile]::CreateFromDirectory here. PowerShell 5.1 runs on .NET
# Framework, which writes backslashes into entry names. Android's unzip would
# then create files literally named "common\audit.sh" instead of a directory
# tree, and the module would not load. Build entries by hand instead.

$sep = [System.IO.Path]::DirectorySeparatorChar
$altSep = [System.IO.Path]::AltDirectorySeparatorChar
$slash = [char]47
$backslash = [char]92

$archive = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
  Get-ChildItem -Path $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    $rel = $_.FullName.Substring($stage.Length)
    while ($rel.Length -gt 0 -and ($rel[0] -eq $sep -or $rel[0] -eq $altSep)) {
      $rel = $rel.Substring(1)
    }
    $entryName = $rel.Replace($sep, $slash)
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $archive,
      $_.FullName,
      $entryName,
      [System.IO.Compression.CompressionLevel]::Optimal
    )
  }
} finally {
  $archive.Dispose()
}

# Refuse to ship a zip whose entry names contain backslashes.
$verify = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
$badEntries = @()
try {
  foreach ($e in $verify.Entries) {
    if ($e.FullName.IndexOf($backslash) -ge 0) { $badEntries += $e.FullName }
  }
} finally {
  $verify.Dispose()
}
if ($badEntries.Count -gt 0) {
  Write-Host 'BACKSLASH IN ZIP ENTRY NAMES:' -ForegroundColor Red
  $badEntries | ForEach-Object { Write-Host "  $_" }
  Remove-Item $zipPath -Force
  exit 1
}
Write-Host '[ok] all zip entries use forward slashes'

Remove-Item $stage -Recurse -Force

$size = (Get-Item $zipPath).Length
Write-Host ''
Write-Host "built: $zipPath" -ForegroundColor Green
Write-Host ("size : {0:N0} bytes" -f $size)
Write-Host ''
Write-Host 'flash it in KernelSU / Magisk, then open the module WebUI.'
