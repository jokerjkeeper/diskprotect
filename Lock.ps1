#Requires -Version 5.1
<#
.SYNOPSIS
    diskProtect 上鎖 — 卸載所有 VHDX,對應磁碟機代號 (J:\、G:\ ...) 從系統消失,任何軟件都看不到內容。
.DESCRIPTION
    對每個已掛載的 volume 執行 Dismount-DiskImage。
    若磁碟正被程式佔用會卸載失敗 —— 請先關閉在用該碟的程式 (IDE、終端機、Fork 等)。
    加 -HideVhdx 會把 vhdx 檔本身設為隱藏+系統屬性 (進一步不顯眼);Unlock 時會自動取消。
    已啟用 BitLocker 的磁碟卸載後即自動回到鎖定狀態,下次掛載必須輸入密碼。
.PARAMETER Name
    只上鎖指定 volume(預設全部)。
.PARAMETER HideVhdx
    卸載後把 vhdx 檔設為隱藏。
#>
[CmdletBinding()]
param([string]$Name, [switch]$HideVhdx)

$ErrorActionPreference = 'Stop'

# --- 自動提權 ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Name)     { $argLine += " -Name `"$Name`"" }
    if ($HideVhdx) { $argLine += " -HideVhdx" }
    Start-Process powershell -Verb RunAs -ArgumentList $argLine
    return
}

$config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$vols = $config.volumes
if ($Name) { $vols = $vols | Where-Object { $_.name -eq $Name } }

foreach ($vol in $vols) {
    $vhdx = $vol.vhdx; $letter = $vol.driveLetter.TrimEnd(':')
    if (-not (Test-Path $vhdx)) { continue }
    $img = Get-DiskImage -ImagePath $vhdx
    if (-not $img.Attached) { Write-Host "略過 $($vol.name):未掛載" -ForegroundColor DarkGray; continue }

    try {
        Write-Host "卸載 $($vol.name) ($letter`:) ..." -ForegroundColor Yellow
        Dismount-DiskImage -ImagePath $vhdx | Out-Null
        if ($HideVhdx) { attrib +h +s $vhdx 2>$null | Out-Null; Write-Host "  已隱藏 vhdx 檔" -ForegroundColor DarkGray }
        Write-Host "✅ $($vol.name) 已上鎖 — $letter`: 已從系統消失" -ForegroundColor Green
    } catch {
        Write-Host "❌ $($vol.name) 卸載失敗(可能有程式正在使用 $letter`:)。請關閉相關程式後重試。" -ForegroundColor Red
        Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Host "`n完成。" -ForegroundColor Green
Read-Host "按 Enter 關閉"
