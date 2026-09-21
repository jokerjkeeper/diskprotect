#Requires -Version 5.1
<#
.SYNOPSIS
    diskProtect 步驟 4 — 對已掛載的 VHDX 磁碟 (例如 J:) 啟用 BitLocker (密碼 + 修復金鑰)。

.DESCRIPTION
    就地加密,不格式化、不刪除任何檔案。加密完成後,vhdx 檔本身就是密文:
    就算被人掛載或整個複製走,沒有密碼也讀不到內容。

    安全閘:
      1. 目標代號必須已掛載,且背後是 'File Backed Virtual' 磁碟,並且正好是 config 裡那個 vhdx
      2. 該磁碟已經加密或正在加密 → 顯示狀態後中止,不重複操作
      3. 修復金鑰目錄不可以位於該 vhdx 磁碟本身 (否則鎖上後就拿不到金鑰)
      4. 修復金鑰寫入檔案後會讀回比對;失敗就把金鑰顯示在畫面上,並要求手動抄下

    一定使用 -UsedSpaceOnly:動態擴充 vhdx 若整碟加密,檔案會膨脹到接近 maxSizeGB。
    不啟用自動解鎖 (自動解鎖會讓上鎖失去意義)。

.PARAMETER Name
    對應 config.json 的 volumes[].name。預設 Git。

.PARAMETER RecoveryKeyDir
    修復金鑰要存放的目錄 (建議放在 vhdx 以外的實體磁碟,例如 H:\diskProtect-keys)。
    未指定時會在執行時詢問。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\04-Enable-BitLocker.ps1
    powershell -ExecutionPolicy Bypass -File .\04-Enable-BitLocker.ps1 -Name Git -RecoveryKeyDir H:\diskProtect-keys
#>
[CmdletBinding()]
param(
    [string]$Name = 'Git',
    [string]$RecoveryKeyDir
)

$ErrorActionPreference = 'Stop'

# --- 自動提權 ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "需要系統管理員權限,正在跳出 UAC 提權視窗..." -ForegroundColor Yellow
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Name `"$Name`""
    if ($RecoveryKeyDir) { $argLine += " -RecoveryKeyDir `"$RecoveryKeyDir`"" }
    Start-Process powershell -Verb RunAs -ArgumentList $argLine
    return
}

# 將 SecureString 轉成明文 (只在本機記憶體內比對兩次輸入是否一致,用完立即清除)
function ConvertTo-PlainText([Security.SecureString]$secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try     { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

try {
    # --- 讀取設定 ---
    $configPath = Join-Path $PSScriptRoot 'config.json'
    if (-not (Test-Path $configPath)) { throw "找不到設定檔:$configPath" }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $vol = $config.volumes | Where-Object { $_.name -eq $Name }
    if (-not $vol) { throw "config.json 裡找不到 volume 名稱:$Name" }

    $vhdxPath   = $vol.vhdx
    $letter     = $vol.driveLetter.TrimEnd(':')
    $mountPoint = "$letter`:"

    Write-Host "`n=========================================" -ForegroundColor Cyan
    Write-Host " diskProtect 步驟 4:啟用 BitLocker ($Name)" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " VHDX     : $vhdxPath"
    Write-Host " 目標代號 : $mountPoint"
    Write-Host ""

    # --- 安全閘 1:已掛載,是虛擬檔案磁碟,且正是 config 裡的那個 vhdx ---
    if (-not (Test-Path $vhdxPath)) { throw "找不到 VHDX:$vhdxPath" }
    $img = Get-DiskImage -ImagePath $vhdxPath
    if (-not $img.Attached) { throw "$Name 尚未掛載。請先跑 Unlock.ps1 讓它出現在 $mountPoint 再執行本腳本。" }

    $disk = $img | Get-Disk
    if ($disk.BusType -ne 'File Backed Virtual') {
        throw "安全中止:磁碟 $($disk.Number) 的 BusType 是 '$($disk.BusType)',不是 'File Backed Virtual'。"
    }
    $partOnLetter = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $partOnLetter -or $partOnLetter.DiskNumber -ne $disk.Number) {
        throw "安全中止:$mountPoint 不是 $vhdxPath 掛載出來的磁碟 (請先跑 Unlock.ps1 確認代號)。"
    }

    # --- 安全閘 2:已經加密 / 正在加密就不重複操作 ---
    $blv = Get-BitLockerVolume -MountPoint $mountPoint
    if ($blv.VolumeStatus -ne 'FullyDecrypted' -or $blv.KeyProtector.Count -gt 0) {
        Write-Host "此磁碟已經啟用或正在處理 BitLocker,不做任何變更:" -ForegroundColor Yellow
        $blv | Format-List MountPoint, VolumeStatus, EncryptionPercentage, ProtectionStatus, LockStatus, EncryptionMethod, KeyProtector
        Read-Host "按 Enter 關閉"
        return
    }

    $usedGB = [math]::Round(((Get-Volume -DriveLetter $letter).Size - (Get-Volume -DriveLetter $letter).SizeRemaining) / 1GB, 1)
    Write-Host " 已用空間 : $usedGB GB (只加密已用空間,vhdx 檔大小大致不變)"
    Write-Host ""

    # --- 安全閘 3:修復金鑰目錄 ---
    if (-not $RecoveryKeyDir) {
        Write-Host "修復金鑰是忘記密碼時唯一的救命繩,必須存放在這顆 vhdx 以外的地方。" -ForegroundColor Yellow
        $RecoveryKeyDir = Read-Host "請輸入修復金鑰存放目錄 (例如 H:\diskProtect-keys)"
    }
    if (-not $RecoveryKeyDir) { throw "未指定修復金鑰目錄,已中止。" }
    $keyDrive = ([IO.Path]::GetPathRoot($RecoveryKeyDir)).TrimEnd('\').TrimEnd(':')
    if ($keyDrive -ieq $letter) { throw "安全中止:修復金鑰不可以存放在 $mountPoint 本身 (鎖上後就拿不到了)。" }
    $vhdxDrive = ([IO.Path]::GetPathRoot($vhdxPath)).TrimEnd('\').TrimEnd(':')
    if ($keyDrive -ieq $vhdxDrive) {
        Write-Host "⚠️  修復金鑰目錄和 vhdx 在同一顆 $vhdxDrive`: 上;這顆硬碟壞掉時會一起遺失。建議另外再抄一份。" -ForegroundColor Yellow
    }
    New-Item -ItemType Directory -Path $RecoveryKeyDir -Force | Out-Null

    # --- 設定密碼 (BitLocker 至少 8 個字元) ---
    $password = $null
    for ($attempt = 1; $attempt -le 3 -and -not $password; $attempt++) {
        $pw1 = Read-Host "設定 BitLocker 密碼 (至少 8 字元)" -AsSecureString
        $pw2 = Read-Host "再輸入一次確認" -AsSecureString
        $plain1 = ConvertTo-PlainText $pw1; $plain2 = ConvertTo-PlainText $pw2
        if ($plain1.Length -lt 8)      { Write-Host "密碼太短,至少 8 字元。" -ForegroundColor Red }
        elseif ($plain1 -cne $plain2)  { Write-Host "兩次輸入不一致。" -ForegroundColor Red }
        else                           { $password = $pw1 }
        $plain1 = $null; $plain2 = $null
    }
    if (-not $password) { throw "密碼設定失敗 3 次,已中止 (未做任何變更)。" }

    Write-Host "`n即將對 $mountPoint 啟用 BitLocker (XTS-AES 256,只加密已用空間)。" -ForegroundColor Yellow
    Write-Host "此操作不會刪除任何資料。建議開始前先關閉正在使用 $mountPoint 的程式。" -ForegroundColor Yellow
    $confirm = Read-Host "確定開始?輸入 YES 繼續"
    if ($confirm -cne 'YES') { Write-Host "已取消,未做任何變更。"; Read-Host "按 Enter 關閉"; return }

    # --- 啟用:先建修復金鑰保護 (從第一刻起就有備援),再加上密碼保護 ---
    Write-Host "`n啟用 BitLocker (修復金鑰保護)..." -ForegroundColor Yellow
    Enable-BitLocker -MountPoint $mountPoint -EncryptionMethod XtsAes256 -UsedSpaceOnly -RecoveryPasswordProtector | Out-Null

    $recovery = (Get-BitLockerVolume -MountPoint $mountPoint).KeyProtector |
        Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    if (-not $recovery) { throw "啟用後找不到修復金鑰保護裝置,請執行 'manage-bde -protectors -get $mountPoint' 檢查。" }

    # --- 安全閘 4:寫入修復金鑰檔並讀回驗證 ---
    $keyFile = Join-Path $RecoveryKeyDir "BitLocker-Recovery-$Name-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $keyText = @"
diskProtect BitLocker 修復金鑰
Volume      : $Name ($mountPoint)
VHDX        : $vhdxPath
建立時間    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
金鑰識別碼  : $($recovery.KeyProtectorId)
修復金鑰    : $($recovery.RecoveryPassword)

用法 (忘記密碼時,先跑 Unlock.ps1 掛載,再於系統管理員 PowerShell 執行):
  manage-bde -unlock $mountPoint -RecoveryPassword $($recovery.RecoveryPassword)
"@
    $keySaved = $false
    try {
        Set-Content -Path $keyFile -Value $keyText -Encoding UTF8
        $keySaved = (Get-Content $keyFile -Raw) -match [regex]::Escape($recovery.RecoveryPassword)
    } catch { $keySaved = $false }

    if ($keySaved) {
        Write-Host "✅ 修復金鑰已存到:$keyFile" -ForegroundColor Green
    } else {
        Write-Host "`n❌ 修復金鑰檔寫入/驗證失敗!請立刻手動抄下以下金鑰:" -ForegroundColor Red
        Write-Host "   識別碼:$($recovery.KeyProtectorId)" -ForegroundColor Red
        Write-Host "   金鑰  :$($recovery.RecoveryPassword)" -ForegroundColor Red
        Read-Host "抄好後按 Enter 繼續"
    }

    Write-Host "加入密碼保護..." -ForegroundColor Yellow
    try {
        Add-BitLockerKeyProtector -MountPoint $mountPoint -PasswordProtector -Password $password | Out-Null
    } catch {
        Write-Host "❌ 加入密碼保護失敗:$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   加密仍會進行,但目前只能用修復金鑰解鎖。可稍後手動執行:" -ForegroundColor Red
        Write-Host "   Add-BitLockerKeyProtector -MountPoint $mountPoint -PasswordProtector -Password (Read-Host -AsSecureString)" -ForegroundColor Red
    }
    $password = $null

    # --- 顯示加密進度 ---
    Write-Host "`n加密進行中。可以關閉此視窗,加密會在背景繼續;" -ForegroundColor Cyan
    Write-Host "中途卸載 (Lock) 也不會損壞資料,下次解鎖後會自動接著跑。但建議等到 100% 再上鎖。" -ForegroundColor Cyan
    do {
        Start-Sleep -Seconds 5
        $blv = Get-BitLockerVolume -MountPoint $mountPoint
        Write-Host ("`r" + ("  {0}  {1,5:N1}%" -f $blv.VolumeStatus, $blv.EncryptionPercentage).PadRight(40)) -NoNewline
    } while ($blv.VolumeStatus -eq 'EncryptionInProgress')

    Write-Host "`n`n✅ 完成:$mountPoint 狀態 = $($blv.VolumeStatus),保護 = $($blv.ProtectionStatus)" -ForegroundColor Green
    Write-Host "   之後 Unlock.ps1 掛載時會要求輸入密碼;Lock.ps1 卸載後自動回到鎖定狀態。" -ForegroundColor Green
} catch {
    Write-Host "`n❌ $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""
Read-Host "按 Enter 關閉此視窗"
