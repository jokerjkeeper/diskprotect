#Requires -Version 5.1
<#
.SYNOPSIS
    diskProtect 狀態 — 顯示每個 volume 的 vhdx 是否存在、是否已掛載、掛在哪個代號、用量。
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'SilentlyContinue'

$config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json

Write-Host ("{0,-6} {1,-16} {2,-8} {3,-8} {4}" -f 'Vol','VHDX','存在','狀態','代號/用量') -ForegroundColor Cyan
Write-Host ('-' * 60)
foreach ($vol in $config.volumes) {
    $vhdx = $vol.vhdx; $letter = $vol.driveLetter.TrimEnd(':')
    $exists = Test-Path $vhdx
    $state = '—'; $info = ''
    if ($exists) {
        $img = Get-DiskImage -ImagePath $vhdx
        if ($img.Attached) {
            $state = '已解鎖'
            $v = Get-Volume -DriveLetter $letter
            if ($v) { $info = "{0}:  {1:N1}/{2:N1} GB 已用" -f $letter, (($v.Size-$v.SizeRemaining)/1GB), ($v.Size/1GB) }
            else    { $info = "(已掛載，代號待查)" }
        } else { $state = '已上鎖' }
    }
    $color = if ($state -eq '已解鎖') { 'Green' } elseif ($state -eq '已上鎖') { 'Yellow' } else { 'DarkGray' }
    Write-Host ("{0,-6} {1,-16} {2,-8} {3,-8} {4}" -f $vol.name, (Split-Path $vhdx -Leaf), $(if($exists){'是'}else{'否'}), $state, $info) -ForegroundColor $color
}
Write-Host ''
