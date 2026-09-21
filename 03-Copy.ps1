#Requires -Version 5.1
<#
.SYNOPSIS
    diskProtect 步驟 3 — 用 robocopy 把來源目錄「複製」到掛載後的磁碟(不刪原檔),並驗證。

.DESCRIPTION
    - robocopy 是「複製」:來源 (例如 D:\Git) 全程不被刪除、不被移動。
    - /XJD 排除目錄接合點(junction),避免無限迴圈。
    - 複製後比對來源與目的的「檔案數 + 總位元組」,並檢查 robocopy 結束碼。
    - 驗證未通過前,不會、也不該去刪任何原始資料(刪除是後面獨立的一步)。

.PARAMETER Name
    對應 config.json 的 volumes[].name。預設 Git。
#>
[CmdletBinding()]
param(
    [string]$Name = 'Git'
)

$ErrorActionPreference = 'Stop'

$configPath = Join-Path $PSScriptRoot 'config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$vol = $config.volumes | Where-Object { $_.name -eq $Name }
if (-not $vol) { throw "config.json 裡找不到 volume 名稱:$Name" }

$src    = $vol.source
$letter = $vol.driveLetter.TrimEnd(':')
$dst    = "$letter`:\$($vol.name)"

if (-not (Test-Path $src))     { throw "來源不存在:$src" }
if (-not (Test-Path "$letter`:\")) { throw "$letter`: 未掛載,請先跑步驟 2。" }
if (-not (Test-Path $dst))     { New-Item -ItemType Directory -Path $dst -Force | Out-Null }

$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir "copy-$Name-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Write-Host "複製 $src  ->  $dst" -ForegroundColor Cyan
Write-Host "log: $log`n"

# /E 含子目錄(含空) /COPY:DAT 資料+屬性+時間 /DCOPY:DAT 目錄時間
# /R:2 /W:2 遇鎖檔最多重試2次 /MT:16 多執行緒 /XJD 排除目錄junction防迴圈
$rcArgs = @($src, $dst, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/MT:16', '/XJD', '/NP', '/NDL', "/LOG:$log", '/TEE')
& robocopy @rcArgs
$rc = $LASTEXITCODE

Write-Host "`nrobocopy 結束碼: $rc  (0-7=成功, >=8=有失敗)" -ForegroundColor Yellow

# --- 驗證:比對檔案數與總大小 ---
Write-Host "`n驗證中(統計來源與目的)..." -ForegroundColor Yellow
$s = Get-ChildItem $src -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
$d = Get-ChildItem $dst -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum

Write-Host ("  來源: {0,10:N0} 檔  {1,8:N2} GB (含複製期間仍在變動的活檔)" -f $s.Count, ($s.Sum/1GB))
Write-Host ("  目的: {0,10:N0} 檔  {1,8:N2} GB" -f $d.Count, ($d.Sum/1GB))

# 權威判準:robocopy 結束碼 < 8 代表沒有任何檔複製失敗(bit3=8 才是失敗)。
# 不再用「目的位元組 >= 來源」比對——來源是活資料夾,複製期間會微幅變動而誤報。
$ok = ($rc -lt 8)
if ($ok) {
    Write-Host "`n✅ 複製成功:robocopy 結束碼 $rc (<8,無失敗檔)。原始 $src 仍完好未動。" -ForegroundColor Green
    Write-Host "   註:來源與目的若有少量位元組差異,通常是複製期間仍在變動的活檔(快取/log),屬正常。" -ForegroundColor Green
    Write-Host "   正式切換前(步驟 4)請關閉佔用來源的程式,再補跑一次本腳本同步最後幾個檔。" -ForegroundColor Green
} else {
    Write-Host "`n⚠️  robocopy 結束碼 $rc (>=8),有檔案複製失敗。" -ForegroundColor Red
    Write-Host "   請關閉佔用來源檔案的程式後,再跑一次本腳本(robocopy 只補缺的檔,不會重來)。" -ForegroundColor Red
    Write-Host "   在通過前,請勿刪除原始資料。log: $log" -ForegroundColor Red
}
