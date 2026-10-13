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
      3. 修復金鑰保存方式在任何變更前先驗證 (與 Rotate-RecoveryKey.ps1 相同規則):
           A. 隨身碟 (-RecoveryKeyDir):只接受卸除式磁碟,本機硬碟與網路磁碟一律拒絕
           B. 只顯示在畫面上 (-ShowOnScreen):抄到紙上 / 密碼管理器,不寫任何檔案
      4. 保存後驗證你真的持有金鑰 (A: 輸入第一組 6 位數;B: 完整輸入 48 位數)

    一定使用 -UsedSpaceOnly:動態擴充 vhdx 若整碟加密,檔案會膨脹到接近 maxSizeGB。
    不啟用自動解鎖 (自動解鎖會讓上鎖失去意義)。

.PARAMETER Name
    對應 config.json 的 volumes[].name。預設 Git。

.PARAMETER RecoveryKeyDir
    隨身碟上的目錄,例如 E:\diskProtect-keys。與 -ShowOnScreen 都未指定時會在執行時詢問。

.PARAMETER ShowOnScreen
    修復金鑰不存檔,只顯示在畫面上。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\04-Enable-BitLocker.ps1 -Name Dev
    powershell -ExecutionPolicy Bypass -File .\04-Enable-BitLocker.ps1 -Name Dev -ShowOnScreen
    powershell -ExecutionPolicy Bypass -File .\04-Enable-BitLocker.ps1 -Name Dev -RecoveryKeyDir E:\diskProtect-keys
#>
[CmdletBinding()]
param(
    [string]$Name = 'Git',
    [string]$RecoveryKeyDir,
    [switch]$ShowOnScreen
)

$ErrorActionPreference = 'Stop'

# 去掉使用者輸入路徑時多帶的引號/空白 (例如從檔案總管「複製路徑」會帶雙引號)
function Get-CleanPath([string]$path) {
    if (-not $path) { return $path }
    return $path.Trim().Trim('"').Trim("'").Trim()
}

# --- 自動提權 ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "需要系統管理員權限,正在跳出 UAC 提權視窗..." -ForegroundColor Yellow
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Name `"$Name`""
    # 結尾反斜線會把後面的引號跳脫掉 ("E:\keys\" -> E:\keys"),先去掉
    $cleanDir = (Get-CleanPath $RecoveryKeyDir)
    if ($cleanDir)     { $argLine += " -RecoveryKeyDir `"$($cleanDir.TrimEnd('\'))`"" }
    if ($ShowOnScreen) { $argLine += " -ShowOnScreen" }
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

    # --- 安全閘 3:決定修復金鑰保存方式並先驗證 (尚未做任何變更) ---
    $RecoveryKeyDir = Get-CleanPath $RecoveryKeyDir
    if (-not $RecoveryKeyDir -and -not $ShowOnScreen) {
        Write-Host "修復金鑰是忘記密碼時唯一的救命繩,要怎麼保存?" -ForegroundColor Cyan
        Write-Host "  1) 存到隨身碟 (請先插上)"
        Write-Host "  2) 只顯示在畫面上,我自己抄到紙上 / 存進密碼管理器 (不寫任何檔案)"
        switch ((Read-Host "請選 1 或 2").Trim()) {
            '1'     { $RecoveryKeyDir = Get-CleanPath (Read-Host "隨身碟上的目錄 (例如 E:\diskProtect-keys)") }
            '2'     { $ShowOnScreen = $true }
            default { throw "未選擇保存方式,已中止 (未做任何變更)。" }
        }
    }
    if (-not $ShowOnScreen) {
        if (-not $RecoveryKeyDir) { throw "未指定隨身碟目錄,已中止 (未做任何變更)。" }
        $root = [IO.Path]::GetPathRoot($RecoveryKeyDir)
        if (-not $root -or $root -notmatch '^[A-Za-z]:\\?$') { throw "路徑格式不正確:'$RecoveryKeyDir' (應為像 E:\diskProtect-keys 的格式)。" }
        $keyDrive = $root.Substring(0, 2).ToUpper()
        $logical = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$keyDrive'"
        if (-not $logical) { throw "找不到磁碟 $keyDrive (隨身碟插上了嗎?)。" }
        if ($logical.DriveType -ne 2) {
            $typeName = switch ($logical.DriveType) { 3 {'本機硬碟'} 4 {'網路磁碟'} default {"類型 $($logical.DriveType)"} }
            throw "安全中止:$keyDrive 是$typeName,不是隨身碟。修復金鑰只能存到卸除式磁碟;沒有隨身碟的話請改用選項 2 (畫面顯示)。"
        }
        New-Item -ItemType Directory -Path $RecoveryKeyDir -Force | Out-Null
    }

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
    # 輸出與警告訊息都含金鑰明文,一律丟棄
    Enable-BitLocker -MountPoint $mountPoint -EncryptionMethod XtsAes256 -UsedSpaceOnly -RecoveryPasswordProtector -WarningAction SilentlyContinue | Out-Null

    $recovery = (Get-BitLockerVolume -MountPoint $mountPoint).KeyProtector |
        Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    if (-not $recovery) { throw "啟用後找不到修復金鑰保護裝置,請以系統管理員執行 '(Get-BitLockerVolume $mountPoint).KeyProtector | Select KeyProtectorType,KeyProtectorId' 檢查。" }
    $recoveryKey = $recovery.RecoveryPassword

    # --- 安全閘 4:保存修復金鑰並驗證你真的持有它 ---
    $verified = $false
    if ($ShowOnScreen) {
        for ($round = 1; $round -le 3 -and -not $verified; $round++) {
            Clear-Host
            Write-Host "`n  ⚠️  請勿截圖 / 拍照上傳。抄到紙上或存進密碼管理器。`n" -ForegroundColor Yellow
            Write-Host "  Volume     : $Name ($mountPoint)"
            Write-Host "  金鑰識別碼 : $($recovery.KeyProtectorId)`n"
            Write-Host "  修復金鑰   : $recoveryKey`n" -ForegroundColor Green
            Read-Host "  抄好後按 Enter (畫面會被清除)" | Out-Null
            Clear-Host
            $typed = Read-Host "請完整輸入剛抄下的 48 位數修復金鑰 (可含或不含 -) [第 $round/3 次]"
            if (($typed -replace '[^0-9]', '') -eq ($recoveryKey -replace '[^0-9]', '')) { $verified = $true }
            else { Write-Host "  不符,可能抄錯了。按 Enter 重新顯示金鑰。" -ForegroundColor Red; Read-Host | Out-Null }
        }
        Clear-Host
    } else {
        $keyFile = Join-Path $RecoveryKeyDir "BitLocker-Recovery-$Name-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
        $keyText = @"
diskProtect BitLocker 修復金鑰
Volume      : $Name ($mountPoint)
VHDX        : $vhdxPath
建立時間    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
金鑰識別碼  : $($recovery.KeyProtectorId)
修復金鑰    : $recoveryKey

用法 (忘記密碼時,先跑 Unlock.ps1 掛載,連續輸錯 3 次密碼後貼上此金鑰;或在系統管理員 PowerShell):
  manage-bde -unlock $mountPoint -RecoveryPassword <上面的修復金鑰>
"@
        $saved = $false
        try {
            Set-Content -Path $keyFile -Value $keyText -Encoding UTF8
            $saved = (Get-Content $keyFile -Raw) -match [regex]::Escape($recoveryKey)
        } catch { $saved = $false }
        if ($saved) {
            Write-Host "✅ 修復金鑰已存到:$keyFile (畫面上不顯示金鑰)" -ForegroundColor Green
            $firstGroup = ($recoveryKey -split '-')[0]
            for ($attempt = 1; $attempt -le 3 -and -not $verified; $attempt++) {
                $typed = Read-Host "請打開上述檔案,輸入修復金鑰的「第一組 6 位數」以確認 (第 $attempt/3 次)"
                if ($typed.Trim() -eq $firstGroup) { $verified = $true } else { Write-Host "  不符。" -ForegroundColor Red }
            }
        } else {
            Write-Host "❌ 修復金鑰檔寫入/驗證失敗:$keyFile" -ForegroundColor Red
        }
    }
    $recoveryKey = $null

    if ($verified) {
        Write-Host "✅ 已確認你持有修復金鑰。" -ForegroundColor Green
    } else {
        # 此時磁碟仍是解鎖狀態,不會鎖死;密碼保護照樣加上,之後可用 Rotate-RecoveryKey.ps1 換一組新金鑰
        Write-Host "⚠️  未確認修復金鑰已保存。加密與密碼保護會繼續,但請在上鎖前執行:" -ForegroundColor Yellow
        Write-Host "   Rotate-RecoveryKey.ps1 -Name $Name -ShowOnScreen   (產生新金鑰並作廢這組)" -ForegroundColor Yellow
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
