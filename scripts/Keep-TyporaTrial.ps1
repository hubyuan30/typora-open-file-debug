<#
.SYNOPSIS
    把 Typora 的试用起点刷新为当天（只改 profile.data 的 _iD 与注册表 IDate）。

.DESCRIPTION
    背景：Typora 1.12.1 在「试用已过期」且「无授权」时，从二级实例打开文件会调用
    showLicensePanel()，而该面板窗口对象已被销毁，抛 TypeError 后中断打开流程，
    表现为「已开一个 md 后再双击新 md 打不开」。

    本脚本把试用起点刷新为当天，使 trailRemains 恒为 15，从而不再进入授权面板分支。
    必须趁 Typora 未运行时执行（否则它退出时会用内存里的旧值覆盖回去）。

    不修改 Typora 安装目录里的任何文件。

.PARAMETER ProfileDir
    Typora 配置目录，默认 $env:APPDATA\Typora

.PARAMETER LogFile
    日志路径，默认脚本同目录 keep.log

.PARAMETER Force
    Typora 正在运行时也强行改写（不推荐，退出时可能被覆盖）

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Keep-TyporaTrial.ps1

.NOTES
    退出码：0 成功/无需改动  2 Typora 运行中跳过  3 profile.data 非 hex  4 非 JSON
#>
[CmdletBinding()]
param(
    [string]$ProfileDir,
    [string]$LogFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot 在 param 默认值里不可靠，放到脚本体内解析
$baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ProfileDir) { $ProfileDir = Join-Path $env:APPDATA 'Typora' }
if (-not $LogFile)    { $LogFile    = Join-Path $baseDir 'keep.log' }

function Write-Log([string]$msg) {
    try {
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
        # 日志超过 200KB 轮转一次
        if ((Get-Item $LogFile).Length -gt 200KB) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
    } catch { }
}

$profilePath = Join-Path $ProfileDir 'profile.data'
$regKey      = 'HKCU:\SOFTWARE\Typora'
$today       = (Get-Date).ToString('M/d/yyyy')     # 与 Typora 内部格式一致，如 9/27/2026

if (-not (Test-Path $profilePath)) {
    Write-Log "跳过：未找到 $profilePath（Typora 可能没装或没运行过）"
    exit 0
}

$running = Get-Process -Name Typora -ErrorAction SilentlyContinue
if ($running -and -not $Force) {
    Write-Log "跳过：Typora 正在运行（pid $($running.Id -join ',')），退出时会把改动覆盖掉"
    exit 2
}

# ---------- 1. 首次备份 ----------
$bak = "$profilePath.bak"
if (-not (Test-Path $bak)) {
    Copy-Item $profilePath $bak -Force
    Write-Log '已备份 profile.data -> profile.data.bak'
}

# ---------- 2. 解码 hex -> JSON ----------
$hex = (Get-Content $profilePath -Raw).Trim()
if ($hex -notmatch '^[0-9a-fA-F]+$' -or ($hex.Length % 2) -ne 0) {
    Write-Log '错误：profile.data 不是合法的 hex 文本，放弃改写'
    exit 3
}
$bytes = New-Object byte[] ($hex.Length / 2)
for ($i = 0; $i -lt $bytes.Length; $i++) {
    $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
}
$json = [System.Text.Encoding]::UTF8.GetString($bytes)

try { $obj = $json | ConvertFrom-Json }
catch { Write-Log '错误：profile.data 解码后不是合法 JSON，放弃改写'; exit 4 }

$old = $obj._iD
if ($old -eq $today) {
    Write-Log "无需改动：_iD 已是今天（$today）"
} else {
    $obj._iD = $today
    $newJson = $obj | ConvertTo-Json -Compress -Depth 20
    $nb = [System.Text.Encoding]::UTF8.GetBytes($newJson)
    $nhex = -join ($nb | ForEach-Object { $_.ToString('x2') })
    # 原子写：先写临时文件再替换
    $tmp = "$profilePath.tmp"
    Set-Content -Path $tmp -Value $nhex -NoNewline -Encoding ascii
    Move-Item $tmp $profilePath -Force
    Write-Log "已刷新 _iD: $old -> $today"
}

# ---------- 3. 同步注册表副本 ----------
try {
    if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
    Set-ItemProperty -Path $regKey -Name IDate -Value $today -Type String
    Write-Log "已同步注册表 HKCU\SOFTWARE\Typora\IDate = $today"
} catch {
    Write-Log "注册表写入失败（不影响 profile.data 的改动）：$($_.Exception.Message)"
}

exit 0
