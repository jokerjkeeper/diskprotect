#Requires -Version 5.1
<#
.SYNOPSIS
    diskProtect 步驟 1 — 只生成一個動態擴充 VHDX 檔案(不掛載、不格式化)。

.DESCRIPTION
    這一步是本工具最安全的動作:僅在 D: 上寫出一個 .vhdx 檔案。
    - 不會碰任何現有檔案或資料夾
    - 不會格式化任何磁碟
    - 不會掛載(掛載/初始化是步驟 2)
    動態擴充(expandable)代表檔案初始很小,隨實際寫入的資料量成長,上限為 maxSizeGB。

.PARAMETER Name
    要生成哪個 volume(對應 config.json 的 volumes[].name)。預設 Git。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\01-Create-Vhdx.ps1
    powershell -ExecutionPolicy Bypass -File .\01-Create-Vhdx.ps1 -Name Dev
#>
[CmdletBinding()]
param(
    [string]$Name = 'Git'
)

$ErrorActionPreference = 'Stop'

# --- 自動提權 (建立 VHDX 需要系統管理員) ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "需要系統管理員權限,正在跳出 UAC 提權視窗..." -ForegroundColor Yellow
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Name `"$Name`""
    Start-Process powershell -Verb RunAs -ArgumentList $argLine
    return
}

# --- 讀取設定 ---
$configPath = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path $configPath)) { throw "找不到設定檔:$configPath" }
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$vol = $config.volumes | Where-Object { $_.name -eq $Name }
if (-not $vol) { throw "config.json 裡找不到 volume 名稱:$Name" }

$vhdxPath   = $vol.vhdx
$maxSizeMB  = [int]$vol.maxSizeGB * 1024
$vhdxDrive  = ($vhdxPath -split ':')[0] + ':'

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host " diskProtect 步驟 1:生成 VHDX ($Name)" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " VHDX 路徑 : $vhdxPath"
Write-Host " 類型      : 動態擴充 (expandable)"
Write-Host " 上限      : $($vol.maxSizeGB) GB"
Write-Host ""

# --- 安全檢查 1:檔案已存在就中止,絕不覆蓋 ---
if (Test-Path $vhdxPath) {
    throw "檔案已存在:$vhdxPath`n為避免覆蓋既有資料已中止。若確定要重建,請先手動刪除或改名該檔。"
}

# --- 安全檢查 2:目標磁碟可用空間 ---
$free = (Get-PSDrive -Name $vhdxDrive.TrimEnd(':')).Free
$freeGB = [math]::Round($free / 1GB, 1)
$needGB = [double]$vol.expectedDataGB * 1.1   # 預估資料量 + 10% 餘裕(動態擴充不會一次佔滿上限)
Write-Host " $vhdxDrive 可用空間 : $freeGB GB (預估需要約 $([math]::Round($needGB,1)) GB)"
if ($freeGB -lt $needGB) {
    throw "$vhdxDrive 可用空間不足(需要約 $needGB GB,只剩 $freeGB GB)。"
}

# --- 用 diskpart 生成(僅 create vdisk,不 attach) ---
$dpScript = Join-Path $env:TEMP "dp_create_$Name.txt"
@"
create vdisk file="$vhdxPath" maximum=$maxSizeMB type=expandable
"@ | Set-Content -Path $dpScript -Encoding ASCII

Write-Host "`n正在生成 VHDX(這一步不會掛載、不會格式化任何東西)..." -ForegroundColor Yellow
$out = & diskpart /s $dpScript 2>&1
Remove-Item $dpScript -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $vhdxPath)) {
    Write-Host $out -ForegroundColor Red
    throw "diskpart 生成 VHDX 失敗(結束碼 $LASTEXITCODE)。"
}

$sizeMB = [math]::Round((Get-Item $vhdxPath).Length / 1MB, 1)
Write-Host "`n✅ 完成。已生成:$vhdxPath" -ForegroundColor Green
Write-Host "   目前實際大小:$sizeMB MB(動態擴充,之後隨資料成長)" -ForegroundColor Green
Write-Host "   此檔尚未掛載、尚未格式化。下一步是「步驟 2:掛載+初始化」。" -ForegroundColor Green
Write-Host ""
Read-Host "按 Enter 關閉此視窗"
