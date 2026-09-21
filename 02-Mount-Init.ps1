#Requires -Version 5.1
<#
.SYNOPSIS
    diskProtect 步驟 2 — 掛載 VHDX、初始化、格式化、指派磁碟機代號。

.DESCRIPTION
    僅對「剛掛載的那顆虛擬檔案磁碟」操作。三重安全閘:
      1. BusType 必須是 'File Backed Virtual'(虛擬 VHDX,不可能是實體硬碟)—— 否則中止
      2. 該磁碟必須是 RAW / 無任何分割區(全新空碟)—— 否則中止,絕不覆蓋既有資料
      3. 目標磁碟機代號必須未被佔用 —— 否則中止
    通過後才 Initialize → New-Partition → Format,並在磁碟下建立同名資料夾(例如 J:\Git)。

.PARAMETER Name
    對應 config.json 的 volumes[].name。預設 Git。
#>
[CmdletBinding()]
param(
    [string]$Name = 'Git'
)

$ErrorActionPreference = 'Stop'

# --- 自動提權 ---
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

$vhdxPath = $vol.vhdx
$letter   = $vol.driveLetter.TrimEnd(':')
$label    = $vol.label
$dataDir  = "$letter`:\$($vol.name)"

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host " diskProtect 步驟 2:掛載+初始化 ($Name)" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " VHDX      : $vhdxPath"
Write-Host " 目標代號  : $letter`:"
Write-Host " 資料夾    : $dataDir"
Write-Host ""

if (-not (Test-Path $vhdxPath)) { throw "找不到 VHDX:$vhdxPath(請先跑步驟 1)。" }

# --- 安全閘 3:代號未被佔用 ---
if (Test-Path "$letter`:\") { throw "磁碟機代號 $letter`: 已被佔用,請改 config.json 或先釋放該代號。" }

# --- 掛載 ---
Write-Host "掛載中..." -ForegroundColor Yellow
Mount-DiskImage -ImagePath $vhdxPath -StorageType VHDX | Out-Null

# 取得剛掛載那顆磁碟(從 image 反查,絕不用寫死的磁碟號)
$disk = $null
for ($i = 0; $i -lt 10 -and -not $disk; $i++) {
    Start-Sleep -Milliseconds 400
    $disk = Get-DiskImage -ImagePath $vhdxPath | Get-Disk -ErrorAction SilentlyContinue
}
if (-not $disk) { throw "掛載後找不到對應磁碟。" }

Write-Host " -> 磁碟號 $($disk.Number) / BusType=$($disk.BusType) / PartitionStyle=$($disk.PartitionStyle)"

# --- 安全閘 1:必須是虛擬檔案磁碟 ---
if ($disk.BusType -ne 'File Backed Virtual') {
    Dismount-DiskImage -ImagePath $vhdxPath | Out-Null
    throw "安全中止:磁碟 $($disk.Number) 的 BusType 是 '$($disk.BusType)',不是 'File Backed Virtual'。已卸載,未做任何變更。"
}

# --- 安全閘 2:必須是全新空碟 ---
$existingParts = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.Type -ne 'Reserved' }
if ($disk.PartitionStyle -ne 'RAW' -and $existingParts) {
    Dismount-DiskImage -ImagePath $vhdxPath | Out-Null
    throw "安全中止:磁碟 $($disk.Number) 已有分割區(非全新空碟),為避免覆蓋資料已卸載。"
}

# --- 初始化 + 分割 + 格式化(只作用於這顆虛擬碟)---
if ($disk.PartitionStyle -eq 'RAW') {
    Write-Host "初始化磁碟 (GPT)..." -ForegroundColor Yellow
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
}

Write-Host "建立分割區並指派 $letter`:..." -ForegroundColor Yellow
New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $letter | Out-Null

Write-Host "格式化 NTFS (標籤 $label)..." -ForegroundColor Yellow
Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false | Out-Null

# --- 建立資料夾 (例如 J:\Git) ---
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

$v = Get-Volume -DriveLetter $letter
Write-Host "`n✅ 完成。" -ForegroundColor Green
Write-Host "   $letter`: 已就緒 — 容量 $([math]::Round($v.Size/1GB,1)) GB / 檔案系統 $($v.FileSystem) / 標籤 $($v.FileSystemLabel)" -ForegroundColor Green
Write-Host "   已建立資料夾:$dataDir" -ForegroundColor Green
Write-Host "   VHDX 目前保持掛載,可直接進行步驟 3(robocopy 搬資料)。" -ForegroundColor Green
Write-Host ""
Read-Host "按 Enter 關閉此視窗"
