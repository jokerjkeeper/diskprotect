#Requires -Version 5.1
<#
.SYNOPSIS
    diskProtect 解鎖 — 掛載所有已存在的 VHDX,還原成設定的磁碟機代號 (例如 J:\、G:\)。
.DESCRIPTION
    對 config.json 裡每個 vhdx 檔存在的 volume:若尚未掛載就掛載,並確保代號正確。
    掛載後對應路徑 (J:\Git、G:\Dev ...) 就會重新出現、可用。
    若該磁碟已啟用 BitLocker (見 04-Enable-BitLocker.ps1),掛載後會要求輸入密碼才解得開。
.PARAMETER Name
    只解鎖指定 volume(預設全部)。
#>
[CmdletBinding()]
param([string]$Name)

$ErrorActionPreference = 'Stop'

# --- 自動提權 ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Name) { $argLine += " -Name `"$Name`"" }
    Start-Process powershell -Verb RunAs -ArgumentList $argLine
    return
}

# 若磁碟被 BitLocker 鎖住就要求輸入密碼 (最多 3 次,之後可改用修復金鑰)。回傳是否已可存取。
function Unlock-BitLockerIfLocked([string]$MountPoint, [string]$VolumeName) {
    try { $blv = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop }
    catch { return $true }   # 查不到 BitLocker 資訊 (例如未加密的磁碟),視為可存取
    if ($blv.LockStatus -ne 'Locked') { return $true }

    Write-Host "🔒 $VolumeName ($MountPoint) 已用 BitLocker 加密,請輸入密碼。" -ForegroundColor Cyan
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $pw = Read-Host "  密碼 (第 $attempt/3 次)" -AsSecureString
        try {
            Unlock-BitLocker -MountPoint $MountPoint -Password $pw -ErrorAction Stop | Out-Null
            return $true
        } catch { Write-Host "  密碼錯誤或解鎖失敗。" -ForegroundColor Red }
    }

    $rk = Read-Host "  改用 48 位數修復金鑰 (直接按 Enter 略過)"
    if ($rk) {
        try {
            Unlock-BitLocker -MountPoint $MountPoint -RecoveryPassword $rk.Trim() -ErrorAction Stop | Out-Null
            return $true
        } catch { Write-Host "  修復金鑰解鎖失敗:$($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host "❌ $VolumeName 已掛載但仍被 BitLocker 鎖住,內容無法存取。可再跑一次 Unlock.ps1 重試。" -ForegroundColor Red
    return $false
}

$config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$vols = $config.volumes
if ($Name) { $vols = $vols | Where-Object { $_.name -eq $Name } }

foreach ($vol in $vols) {
    $vhdx = $vol.vhdx; $letter = $vol.driveLetter.TrimEnd(':')
    if (-not (Test-Path $vhdx)) { Write-Host "略過 $($vol.name):找不到 $vhdx" -ForegroundColor DarkGray; continue }

    # 若 vhdx 被設為隱藏,先取消隱藏,才能穩定掛載/顯示
    attrib -h -s $vhdx 2>$null | Out-Null

    $img = Get-DiskImage -ImagePath $vhdx
    if (-not $img.Attached) {
        Write-Host "掛載 $($vol.name) ($vhdx) ..." -ForegroundColor Yellow
        Mount-DiskImage -ImagePath $vhdx -StorageType VHDX | Out-Null
        Start-Sleep -Milliseconds 400
    }

    $disk = Get-DiskImage -ImagePath $vhdx | Get-Disk
    $part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 100MB } | Sort-Object Size -Descending | Select-Object -First 1

    if ($part.DriveLetter -ne $letter) {
        if (Test-Path "$letter`:\") {
            Write-Host "⚠️ $($vol.name):代號 $letter`: 已被佔用,目前掛在 $($part.DriveLetter):" -ForegroundColor Red
        } else {
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter
            Write-Host "  指派代號 -> $letter`:" -ForegroundColor DarkGray
        }
    }

    # --- BitLocker:若該磁碟已加密且處於鎖定,要求輸入密碼 ---
    $actualLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter
    if (-not (Unlock-BitLockerIfLocked -MountPoint "$actualLetter`:" -VolumeName $vol.name)) { continue }

    Write-Host "✅ $($vol.name) 已解鎖 -> $actualLetter`:\$($vol.name)" -ForegroundColor Green
}
Write-Host "`n完成。相關路徑已恢復可用。" -ForegroundColor Green
Read-Host "按 Enter 關閉"
