<#
  serve.ps1 - serve webroot/ over HTTP for local panel testing.

  The panel normally runs inside the KernelSU WebUI, which injects a `ksu`
  object. A plain browser has no such object, so buttons do nothing here
  unless you inject a stub yourself. This server exists so the layout,
  contrast and script errors can be checked without flashing the module.

  Usage:
    powershell -ExecutionPolicy Bypass -File tools\serve.ps1
    powershell -ExecutionPolicy Bypass -File tools\serve.ps1 -Port 9000
#>
param(
  [int]$Port = 8791,
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Root) {
  $Root = Join-Path (Split-Path -Parent $PSScriptRoot) 'webroot'
}
if (-not (Test-Path $Root)) {
  Write-Host "webroot not found: $Root" -ForegroundColor Red
  exit 1
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

$logPath = Join-Path $PSScriptRoot '.serve.log'
Set-Content -Path $logPath -Value "root=$Root" -Encoding utf8
Write-Host "serving $Root at http://127.0.0.1:$Port/"

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
  } catch {
    break
  }

  $rel = $ctx.Request.Url.LocalPath.TrimStart('/')
  if ([string]::IsNullOrEmpty($rel)) { $rel = 'index.html' }

  # Stay inside webroot: reject anything that walks upward.
  $full = [System.IO.Path]::GetFullPath((Join-Path $Root $rel))
  $baseFull = [System.IO.Path]::GetFullPath($Root)
  $inside = $full.StartsWith($baseFull)
  $isLeaf = Test-Path -LiteralPath $full -PathType Leaf
  Add-Content -Path $logPath -Value ("rel=$rel inside=$inside leaf=$isLeaf full=$full") -Encoding utf8

  if (-not $inside -or -not $isLeaf) {
    $ctx.Response.StatusCode = 404
    $ctx.Response.Close()
    continue
  }

  $bytes = [System.IO.File]::ReadAllBytes($full)
  $ext = [System.IO.Path]::GetExtension($full).ToLower()

  if ($ext -eq '.html') { $ctx.Response.ContentType = 'text/html; charset=utf-8' }
  elseif ($ext -eq '.css') { $ctx.Response.ContentType = 'text/css; charset=utf-8' }
  elseif ($ext -eq '.js') { $ctx.Response.ContentType = 'application/javascript; charset=utf-8' }
  else { $ctx.Response.ContentType = 'application/octet-stream' }

  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}
