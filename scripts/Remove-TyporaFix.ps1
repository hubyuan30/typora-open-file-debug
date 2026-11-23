<#
.SYNOPSIS
    回滚 Typora 修复：还原 .md 关联、删除登录触发项、可选还原 profile.data。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Remove-TyporaFix.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Remove-TyporaFix.ps1 -RestoreProfile
#>
[CmdletBinding()]
param(
    [string]$TyporaExe,
    [switch]$RestoreProfile
)

$ErrorActionPreference = 'Continue'
$root     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$taskName = 'TyporaTrialKeep'
$assocKey = 'HKCU:\SOFTWARE\Classes\Typora.md\shell\open\command'
$bak      = Join-Path $root 'association-backup.txt'

Write-Host '==== Typora 修复回滚 ====' -ForegroundColor Cyan

# ---------- 1. 关联 ----------
$old = $null
if (Test-Path $bak) { $old = (Get-Content $bak -Raw).Trim() }
if (-not $old) {
    if (-not $TyporaExe) { $TyporaExe = 'Typora.exe' }
    $old = '"' + $TyporaExe + '" "%1"'
    Write-Host '    未找到备份，按默认命令还原' -ForegroundColor Yellow
}
Set-Item -Path $assocKey -Value $old
Write-Host "    关联已还原: $old" -ForegroundColor Green

# ---------- 2. 登录触发 ----------
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
schtasks /Delete /TN $taskName /F 2>$null | Out-Null
Write-Host '    计划任务已删除（若不存在则忽略）' -ForegroundColor Green

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'TyporaTrialKeep.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "    启动项已删除: $lnk" -ForegroundColor Green }

# ---------- 3. 快捷方式 ----------
$ws = New-Object -ComObject WScript.Shell
foreach ($l in @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Typora\Typora.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Typora.lnk')
)) {
    if (Test-Path "$l.bak") {
        Copy-Item "$l.bak" $l -Force
        Write-Host "    快捷方式已还原: $l" -ForegroundColor Green
    }
}

# ---------- 4. 试用状态 ----------
if ($RestoreProfile) {
    $pf = Join-Path $env:APPDATA 'Typora\profile.data'
    if (Test-Path "$pf.bak") {
        Copy-Item "$pf.bak" $pf -Force
        Write-Host '    profile.data 已还原为备份内容' -ForegroundColor Green
    } else {
        Write-Host '    未找到 profile.data.bak，跳过' -ForegroundColor Yellow
    }
}

Write-Host "`n完成。" -ForegroundColor Cyan
