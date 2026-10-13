# diskProtect

用 Windows 內建的 VHDX 虛擬磁碟,把目錄「打包」成可掛載/卸載的容器。
**卸載(上鎖)後,對應磁碟機代號從系統消失,檔案總管與其他軟件都看不到內容。**

> 操作位置固定在 `D:\diskProtect`(不可放進 `J:`/`G:` 或被搬走的目錄,否則 Unlock 時工具本身會不見)。
> 所有掛載/卸載動作都需要系統管理員權限,腳本會自動跳 UAC。

## 設定 `config.json`

每個 volume 一筆:
- `vhdx`：容器檔路徑(放 `D:\`)
- `maxSizeGB`：動態擴充上限(實佔隨資料成長)
- `driveLetter`：掛載後的代號(如 `J`、`G`)
- `source`：原始來源目錄(僅搬移時用)
- `expectedDataGB`：搬移前空間檢查用

目前:`Git → D:\Document\diskProtect\Git.vhdx → J:`(250G,已完成,BitLocker)、`Dev → D:\Document\diskProtect\Dev.vhdx → G:`(50G,2026-09-22 建立並搬移 D:\Dev)。

## 日常使用

```powershell
# 查狀態(免管理員)
powershell -ExecutionPolicy Bypass -File D:\diskProtect\Status.ps1

# 解鎖 = 掛載,J:\Git、G:\Dev 出現可用
powershell -ExecutionPolicy Bypass -File D:\diskProtect\Unlock.ps1

# 上鎖 = 卸載,代號消失、內容隱藏(先關掉在用該碟的程式)
powershell -ExecutionPolicy Bypass -File D:\diskProtect\Lock.ps1

# 上鎖並把 vhdx 檔本身也設為隱藏
powershell -ExecutionPolicy Bypass -File D:\diskProtect\Lock.ps1 -HideVhdx

# 只針對單一 volume
... Unlock.ps1 -Name Git
```

- 重開機後 VHDX 預設不自動掛載(等於開機即上鎖狀態);要用時跑 Unlock。

## 建立新容器 + 搬移資料(以 Dev 為例)

```powershell
# 1) 生成 vhdx（只建檔，不掛載、不格式化）
... 01-Create-Vhdx.ps1 -Name Dev
# 2) 掛載 + 初始化 + 格式化 + 指派代號（三重安全閘）
... 02-Mount-Init.ps1 -Name Dev
# 3) robocopy 複製來源 → 容器（複製，不刪原檔）+ 驗證
... 03-Copy.ps1 -Name Dev
# 4) 關閉相關程式，再跑一次 03-Copy 補活檔；確認無誤後才改名原目錄留備份
```

## Fork (git GUI) 路徑切換

搬移後把 Fork 倉庫路徑整批改到新碟(Fork 需先完全關閉）:

```powershell
... Switch-ForkToJ.ps1                              # D:\Git\ -> J:\Git\
... Switch-ForkToJ.ps1 -From 'D:\Dev\' -To 'G:\Dev\'  # Dev 搬移後
```
會先備份 `settings.json`,並在替換後驗證 JSON 合法。

## 進階(之後可加)

- BitLocker 加密 vhdx:卸載後即使容器檔被整個複製走也打不開。
- 開機自動掛載 / 開機保持上鎖,依需求調整。
