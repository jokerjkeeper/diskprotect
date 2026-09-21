#Requires -Version 5.1
<#
.SYNOPSIS
    diskProtect — 更換 BitLocker 修復金鑰 (新增新金鑰 → 保存並驗證 → 刪除舊金鑰)。

.DESCRIPTION
    只更換「修復金鑰保護裝置」,不會重新加密資料、不會改動密碼,幾秒內完成。
    用於舊修復金鑰可能外洩 (例如出現在截圖、存放位置不安全) 的情況。

    新金鑰的保存方式 (兩者擇一):
      A. 存到「隨身碟」 (-RecoveryKeyDir)
         只接受卸除式磁碟;本機硬碟 (C:/D:/J: ...) 與網路磁碟一律拒絕 ——
         鑰匙必須離開這台電腦,且不能放在共用網路空間。
      B. 只顯示在畫面上 (-ShowOnScreen),讓你抄到紙上或存進密碼管理器;
         抄完後會清除畫面,再要求完整輸入一次 48 位數,確保沒抄錯。不寫入任何檔案。

    流程與安全閘:
      1. 磁碟必須已掛載且已用密碼解鎖 (Unlock.ps1)
      2. 保存位置先驗證,驗證不過就中止 (此時尚未做任何變更)
      3. 新增新修復金鑰 → 保存
      4. 驗證你真的持有新金鑰 (A: 輸入第一組 6 位數;B: 輸入完整 48 位數) → 才刪除舊金鑰
      5. 刪除後確認舊金鑰已不在清單中

.PARAMETER Name
    對應 config.json 的 volumes[].name。預設 Git。

.PARAMETER RecoveryKeyDir
    隨身碟上的目錄,例如 E:\diskProtect-keys。

.PARAMETER ShowOnScreen
    不存檔,只顯示在畫面上。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Rotate-RecoveryKey.ps1 -ShowOnScreen
    powershell -ExecutionPolicy Bypass -File .\Rotate-RecoveryKey.ps1 -RecoveryKeyDir E:\diskProtect-keys
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

try {
    # --- 讀取設定 ---
    $config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
    $vol = $config.volumes | Where-Object { $_.name -eq $Name }
    if (-not $vol) { throw "config.json 裡找不到 volume 名稱:$Name" }

    $vhdxPath   = $vol.vhdx
    $letter     = $vol.driveLetter.TrimEnd(':')
    $mountPoint = "$letter`:"

    Write-Host "`n=========================================" -ForegroundColor Cyan
    Write-Host " diskProtect:更換修復金鑰 ($Name)" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 不會重新加密、不會改密碼,只換修復金鑰。`n"

    # --- 安全閘 1:已掛載、是這個 vhdx、已解鎖 ---
    $img = Get-DiskImage -ImagePath $vhdxPath
    if (-not $img.Attached) { throw "$Name 尚未掛載。請先跑 Unlock.ps1。" }
    $disk = $img | Get-Disk
    $partOnLetter = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $partOnLetter -or $partOnLetter.DiskNumber -ne $disk.Number) {
        throw "安全中止:$mountPoint 不是 $vhdxPath 掛載出來的磁碟。"
    }
    $blv = Get-BitLockerVolume -MountPoint $mountPoint
    if ($blv.LockStatus -ne 'Unlocked') { throw "$mountPoint 仍被 BitLocker 鎖住,請先跑 Unlock.ps1 輸入密碼。" }
    if ($blv.VolumeStatus -eq 'FullyDecrypted') { throw "$mountPoint 尚未啟用 BitLocker,請改用 04-Enable-BitLocker.ps1。" }

    $oldRecovery = @($blv.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
    $oldIds      = @($oldRecovery | ForEach-Object { $_.KeyProtectorId })
    Write-Host " 目前保護裝置:"
    $blv.KeyProtector | ForEach-Object { Write-Host "   - $($_.KeyProtectorType)  $($_.KeyProtectorId)" }
    if (-not ($blv.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'Password' })) {
        Write-Host "⚠️  目前沒有「密碼」保護裝置;換完後只能靠新修復金鑰解鎖。" -ForegroundColor Yellow
    }
    Write-Host ""

    # --- 安全閘 2:決定保存方式並先驗證 (尚未做任何變更) ---
    $RecoveryKeyDir = Get-CleanPath $RecoveryKeyDir
    if (-not $RecoveryKeyDir -and -not $ShowOnScreen) {
        Write-Host "新修復金鑰要怎麼保存?" -ForegroundColor Cyan
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

    # --- 3. 新增新修復金鑰 (輸出含金鑰明文,一律丟棄) ---
    Write-Host "`n新增新修復金鑰..." -ForegroundColor Yellow
    Add-BitLockerKeyProtector -MountPoint $mountPoint -RecoveryPasswordProtector -WarningAction SilentlyContinue | Out-Null
    $newRecovery = (Get-BitLockerVolume -MountPoint $mountPoint).KeyProtector |
        Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' -and $oldIds -notcontains $_.KeyProtectorId } |
        Select-Object -First 1
    if (-not $newRecovery) { throw "新增後找不到新的修復金鑰保護裝置 (舊金鑰仍有效,未刪除任何東西)。" }
    $newKey = $newRecovery.RecoveryPassword

    # --- 保存 + 安全閘 4:驗證你真的持有新金鑰 ---
    $verified = $false
    $keyFile  = $null
    if ($ShowOnScreen) {
        for ($round = 1; $round -le 3 -and -not $verified; $round++) {
            Clear-Host
            Write-Host "`n  ⚠️  請勿截圖 / 拍照上傳。抄到紙上或存進密碼管理器。`n" -ForegroundColor Yellow
            Write-Host "  Volume     : $Name ($mountPoint)"
            Write-Host "  金鑰識別碼 : $($newRecovery.KeyProtectorId)`n"
            Write-Host "  修復金鑰   : $newKey`n" -ForegroundColor Green
            Read-Host "  抄好後按 Enter (畫面會被清除)" | Out-Null
            Clear-Host
            $typed = Read-Host "請完整輸入剛抄下的 48 位數修復金鑰 (可含或不含 -) [第 $round/3 次]"
            if (($typed -replace '[^0-9]', '') -eq ($newKey -replace '[^0-9]', '')) { $verified = $true }
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
金鑰識別碼  : $($newRecovery.KeyProtectorId)
修復金鑰    : $newKey

用法 (忘記密碼時,先跑 Unlock.ps1 掛載,連續輸錯 3 次密碼後貼上此金鑰;或在系統管理員 PowerShell):
  manage-bde -unlock $mountPoint -RecoveryPassword <上面的修復金鑰>
"@
        Set-Content -Path $keyFile -Value $keyText -Encoding UTF8
        if ((Get-Content $keyFile -Raw) -notmatch [regex]::Escape($newKey)) {
            throw "新金鑰檔寫入驗證失敗:$keyFile。舊金鑰仍有效,未刪除任何東西。"
        }
        Write-Host "✅ 新修復金鑰已存到:$keyFile (畫面上不顯示金鑰)" -ForegroundColor Green
        $firstGroup = ($newKey -split '-')[0]
        for ($attempt = 1; $attempt -le 3 -and -not $verified; $attempt++) {
            $typed = Read-Host "請打開上述檔案,輸入新修復金鑰的「第一組 6 位數」以確認 (第 $attempt/3 次)"
            if ($typed.Trim() -eq $firstGroup) { $verified = $true } else { Write-Host "  不符。" -ForegroundColor Red }
        }
    }
    $newKey = $null

    if (-not $verified) {
        throw "未通過確認,舊金鑰保留未刪 (目前新舊兩組都有效,不會鎖死)。可再跑一次本腳本重來。"
    }
    Write-Host "✅ 已確認你持有新修復金鑰。" -ForegroundColor Green

    # --- 刪除舊修復金鑰 ---
    foreach ($old in $oldRecovery) {
        Write-Host "刪除舊修復金鑰 $($old.KeyProtectorId) ..." -ForegroundColor Yellow
        Remove-BitLockerKeyProtector -MountPoint $mountPoint -KeyProtectorId $old.KeyProtectorId | Out-Null
    }

    # --- 5. 最終確認 ---
    $final = (Get-BitLockerVolume -MountPoint $mountPoint).KeyProtector
    Write-Host "`n目前保護裝置:"
    $final | ForEach-Object { Write-Host "   - $($_.KeyProtectorType)  $($_.KeyProtectorId)" }
    if ($final | Where-Object { $oldIds -contains $_.KeyProtectorId }) { throw "仍有舊修復金鑰未刪除,請檢查上方清單。" }
    Write-Host "`n✅ 完成:舊修復金鑰已失效。" -ForegroundColor Green

    # --- 清理已失效的舊金鑰檔 (只找本腳本目錄,且需確認) ---
    $staleFiles = Get-ChildItem -Path $PSScriptRoot -Filter "BitLocker-Recovery-$Name-*.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $keyFile }
    if ($staleFiles) {
        Write-Host "`n以下舊金鑰檔已失效,且與 vhdx 放在一起:" -ForegroundColor Yellow
        $staleFiles | ForEach-Object { Write-Host "   $($_.FullName)" }
        if ((Read-Host "要刪除嗎?(Y/N)") -ieq 'Y') {
            $staleFiles | Remove-Item -Force
            Write-Host "已刪除。" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "`n❌ $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""
Read-Host "按 Enter 關閉此視窗"
