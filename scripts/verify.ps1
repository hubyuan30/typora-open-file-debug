<#
.SYNOPSIS
    Typora 修复自检：核对试用状态、文件关联、登录触发项，并检查最近日志。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File verify.ps1
#>
[CmdletBinding()]
param(
    [string]$TyporaLog,
    [string]$ProfileDir
)

$ErrorActionPreference = 'Continue'
if (-not $TyporaLog)  { $TyporaLog  = Join-Path $env:APPDATA 'Typora\typora.log' }
if (-not $ProfileDir) { $ProfileDir = Join-Path $env:APPDATA 'Typora' }

$ok = $true

Write-Output '--- 1. 试用状态 ---'
$pf = Join-Path $ProfileDir 'profile.data'
if (Test-Path $pf) {
    $hex = (Get-Content $pf -Raw).Trim()
    if ($hex -match '^[0-9a-fA-F]+$' -and ($hex.Length % 2) -eq 0) {
        $bytes = New-Object byte[] ($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
        }
        $j = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        Write-Output "  profile._iD      = $($j._iD)"
        $expect = (Get-Date).ToString('M/d/yyyy')
        if ($j._iD -ne $expect) {
            Write-Output "  ⚠ 期望今天（$expect），实际 $($j._iD) -> trailRemains 可能不是 15"
            $ok = $false
        } else {
            Write-Output '  ✓ 已是今天'
        }
    } else {
        Write-Output '  ✗ profile.data 不是合法 hex'
        $ok = $false
    }
} else {
    Write-Output "  ✗ 未找到 $pf"
    $ok = $false
}

$regVal = (Get-ItemProperty 'HKCU:\SOFTWARE\Typora' -ErrorAction SilentlyContinue).IDate
Write-Output "  注册表 IDate     = $regVal"
Write-Output "  备份存在         = $(Test-Path "$pf.bak")"

Write-Output '--- 2. 文件关联 ---'
$assoc = (Get-ItemProperty 'HKCU:\SOFTWARE\Classes\Typora.md\shell\open\command' -ErrorAction SilentlyContinue).'(default)'
Write-Output "  $assoc"
if ($assoc -notlike '*Typora*') {
    Write-Output '  ⚠ 关联里没有 Typora'
    $ok = $false
}

Write-Output '--- 3. 登录触发 ---'
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'TyporaTrialKeep.lnk'
$task = Get-ScheduledTask -TaskName 'TyporaTrialKeep' -ErrorAction SilentlyContinue
Write-Output "  启动文件夹项 = $(Test-Path $lnk)"
Write-Output "  计划任务     = $(if ($task) { '存在' } else { '无' })"
if (-not (Test-Path $lnk) -and -not $task) {
    Write-Output '  ⚠ 没有任何登录触发项'
    $ok = $false
}

Write-Output '--- 4. 最近日志 ---'
if (Test-Path $TyporaLog) {
    $tail = Get-Content $TyporaLog -Encoding UTF8 -Tail 400
    $tail | Where-Object {
        $_ -match 'trail remains|hasL|readContentFrom|Object has been destroyed|showLicensePanel|Integrity check failed'
    } | Select-Object -Last 10 | ForEach-Object { Write-Output "  $_" }

    $crashedNow = [bool]($tail -match 'Object has been destroyed')
    Write-Output "  最近出现授权面板崩溃 = $(if ($crashedNow) { '是' } else { '否' })"
} else {
    Write-Output "  ⚠ 未找到 $TyporaLog"
}

Write-Output ''
if ($ok) { Write-Host '结论：通过' -ForegroundColor Green }
else     { Write-Host '结论：需要检查上面标 ⚠ / ✗ 的项' -ForegroundColor Yellow }
