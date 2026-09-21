#Requires -Version 5.1
<#
.SYNOPSIS
    把 Fork (git-fork.com) 的 settings.json 裡指定路徑前綴整批替換 (預設 D:\Git\ -> J:\Git\)。

.DESCRIPTION
    安全措施:
      1. Fork 執行中則中止(否則關閉時會覆寫掉改動)
      2. 先備份 settings.json -> settings.json.bak-<timestamp>
      3. 只替換「精準前綴」(預設 D:\Git\),不動 D:\OlgCase\、D:\Dev\ 等其他路徑
      4. 替換後用 ConvertFrom-Json 驗證檔案仍是合法 JSON;不合法則自動還原備份

.PARAMETER From
    來源路徑前綴,預設 'D:\Git\'。

.PARAMETER To
    目標路徑前綴,預設 'J:\Git\'。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Switch-ForkToJ.ps1
    powershell -ExecutionPolicy Bypass -File .\Switch-ForkToJ.ps1 -From 'D:\Dev\' -To 'G:\Dev\'
#>
[CmdletBinding()]
param(
    [string]$From = 'D:\Git\',
    [string]$To   = 'J:\Git\'
)

$ErrorActionPreference = 'Stop'

$settings = Join-Path $env:LOCALAPPDATA 'Fork\settings.json'
if (-not (Test-Path $settings)) { throw "找不到 Fork 設定檔:$settings" }

# --- 安全閘 1:Fork 不可執行中 ---
if (Get-Process -Name Fork -ErrorAction SilentlyContinue) {
    throw "Fork 正在執行。請先完全關閉 Fork 再跑本腳本(否則改動會被覆寫)。"
}

# JSON 轉義:檔案內反斜線是雙寫的,例如 D:\Git\ 在檔案裡是 D:\\Git\\
$fromEsc = $From -replace '\\', '\\'   # D:\Git\  -> D:\\Git\\
$toEsc   = $To   -replace '\\', '\\'

$raw = Get-Content $settings -Raw
$before = ([regex]::Matches($raw, [regex]::Escape($fromEsc))).Count
Write-Host "設定檔      : $settings"
Write-Host "替換前綴    : '$From'  ->  '$To'"
Write-Host "檔案內比對  : '$fromEsc'  ->  '$toEsc'"
Write-Host "找到        : $before 處"

if ($before -eq 0) { Write-Host "沒有可替換的項目,結束。" -ForegroundColor Yellow; return }

# --- 備份 ---
$bak = "$settings.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $settings $bak -Force
Write-Host "已備份      : $bak" -ForegroundColor Green

# --- 替換 ---
$new = $raw.Replace($fromEsc, $toEsc)
Set-Content -Path $settings -Value $new -Encoding UTF8 -NoNewline

# --- 安全閘 4:驗證仍是合法 JSON ---
try {
    Get-Content $settings -Raw | ConvertFrom-Json | Out-Null
    $after = ([regex]::Matches((Get-Content $settings -Raw), [regex]::Escape($fromEsc))).Count
    Write-Host "`n✅ 完成:已替換 $before 處,剩餘未替換 $after 處。JSON 驗證通過。" -ForegroundColor Green
    Write-Host "   備份在:$bak(要還原就把它複製回 settings.json)" -ForegroundColor Green
    Write-Host "   現在可以重新開啟 Fork。" -ForegroundColor Green
} catch {
    Copy-Item $bak $settings -Force
    throw "替換後 JSON 驗證失敗,已自動還原備份。原因:$($_.Exception.Message)"
}
