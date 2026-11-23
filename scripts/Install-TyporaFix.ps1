<#
.SYNOPSIS
    安装「Typora 已开一个 md 后双击新 md 打不开」的修复。

.DESCRIPTION
    全部改动都在用户态（HKCU + 计划任务/启动文件夹），不修改 Typora 安装目录里的任何文件
    （Typora 1.12 有 SHA256 自校验，改程序会以 Integrity check failed 退出）。

    默认行为：
      - 立即刷新一次试用状态
      - .md 关联指向 Typora.exe 本体（无黑窗）
      - 登录时隐藏执行一次保活

.PARAMETER TyporaExe
    Typora 主程序路径。留空则自动探测（App Paths 注册表 -> 常见安装路径）。

.PARAMETER Wrapper
    把 .md 关联指向包装器 TyporaOpen.cmd（每次打开前都刷新，代价是短暂 cmd 黑窗）。

.PARAMETER NoAssoc
    不改 .md 关联。

.PARAMETER NoTask
    不创建登录触发项。

.PARAMETER FixShortcuts
    顺带把开始菜单/桌面里的 Typora 快捷方式也指向目标（原 .lnk 备份为 .lnk.bak）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Install-TyporaFix.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Install-TyporaFix.ps1 -Wrapper -FixShortcuts
#>
[CmdletBinding()]
param(
    [string]$TyporaExe,
    [switch]$Wrapper,
    [switch]$NoAssoc,
    [switch]$NoTask,
    [switch]$FixShortcuts
)

$ErrorActionPreference = 'Stop'
$root     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$keep     = Join-Path $root 'Keep-TyporaTrial.ps1'
$openCmd  = Join-Path $root 'TyporaOpen.cmd'
$taskName = 'TyporaTrialKeep'
$assocKey = 'HKCU:\SOFTWARE\Classes\Typora.md\shell\open\command'
$backupFile = Join-Path $root 'association-backup.txt'

function Resolve-TyporaExe {
    param([string]$Hint)
    if ($Hint) {
        if (-not (Test-Path $Hint)) { throw "指定的路径不存在：$Hint" }
        return (Resolve-Path $Hint).Path
    }
    foreach ($k in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Typora.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Typora.exe'
    )) {
        if (Test-Path $k) {
            $p = (Get-ItemProperty $k).'(default)'
            if ($p -and (Test-Path $p)) { return (Resolve-Path $p).Path }
        }
    }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)
    foreach ($r in $roots) {
        if (-not $r) { continue }
        foreach ($sub in @('Typora\Typora.exe', 'Programs\Typora\Typora.exe')) {
            $p = Join-Path $r $sub
            if (Test-Path $p) { return $p }
        }
    }

    throw '未找到 Typora.exe，请用 -TyporaExe 显式指定'
}

Write-Host '==== Typora 修复安装 ====' -ForegroundColor Cyan

$TyporaExe = Resolve-TyporaExe -Hint $TyporaExe
Write-Host "Typora: $TyporaExe"
if (-not (Test-Path $keep))    { throw "缺少文件: $keep" }
if (-not (Test-Path $openCmd)) { throw "缺少文件: $openCmd" }

# ---------- 1. 立即刷新一次 ----------
Write-Host "`n[1/3] 刷新试用状态 ..." -ForegroundColor Yellow
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File', $keep
) -Wait -PassThru -WindowStyle Hidden
switch ($p.ExitCode) {
    0 { Write-Host '    OK（已刷新或本就无需刷新）' -ForegroundColor Green }
    2 { Write-Host '    Typora 正在运行，已跳过。请先完全退出 Typora 再重跑本脚本。' -ForegroundColor Yellow }
    default { Write-Host "    返回码 $($p.ExitCode)，详见 keep.log" -ForegroundColor Yellow }
}

# ---------- 2. 文件关联 ----------
if (-not $NoAssoc) {
    Write-Host "`n[2/3] 处理 .md 打开命令 ..." -ForegroundColor Yellow
    $cur = Get-Item $assocKey -ErrorAction SilentlyContinue
    $curCmd = if ($cur) { $cur.GetValue('') } else { '' }

    if ($curCmd -notlike '*Typora*') {
        Set-Content -Path $backupFile -Value $curCmd -Encoding UTF8
        Write-Host "    已备份原命令 -> $backupFile"
    } else {
        Write-Host '    原命令已指向 Typora，跳过备份'
    }

    if ($Wrapper) {
        $newCmd = 'cmd.exe /c ""' + $openCmd + '" "%1""'
        Write-Host '    模式：包装器（每次打开前刷新，会有短暂黑窗）' -ForegroundColor Gray
    } else {
        $newCmd = '"' + $TyporaExe + '" "%1"'
        Write-Host '    模式：直连 Typora.exe（无黑窗，靠登录时刷新）' -ForegroundColor Gray
    }
    New-Item -Path $assocKey -Force | Out-Null
    Set-Item -Path $assocKey -Value $newCmd
}

# ---------- 3. 登录触发 ----------
if (-not $NoTask) {
    Write-Host "`n[3/3] 登录触发保活 ..." -ForegroundColor Yellow
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $keep + '"')
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

    $registered = $false
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Description 'Typora 试用状态保活（仅改 profile.data._iD 与注册表 IDate）' `
            -Force | Out-Null
        Write-Host '    计划任务创建成功' -ForegroundColor Green
        $registered = $true
    } catch {
        Write-Host "    Register-ScheduledTask 失败：$($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '    改用 schtasks ...' -ForegroundColor Yellow
        $tr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $keep + '"'
        schtasks /Create /TN $taskName /TR $tr /SC ONLOGON /F 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host '    schtasks 创建成功' -ForegroundColor Green
            $registered = $true
        }
    }

    if (-not $registered) {
        Write-Host '    计划任务需要管理员权限，改用启动文件夹（效果等价，免提权）...' -ForegroundColor Yellow
        $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'TyporaTrialKeep.lnk'
        $ws  = New-Object -ComObject WScript.Shell
        $sc  = $ws.CreateShortcut($lnk)
        $sc.TargetPath       = 'powershell.exe'
        $sc.Arguments        = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $keep + '"'
        $sc.WorkingDirectory = $root
        $sc.WindowStyle      = 7
        $sc.IconLocation     = "$TyporaExe,0"
        $sc.Description      = 'Typora 试用状态保活（登录时运行）'
        $sc.Save()
        if (Test-Path $lnk) { Write-Host "    已放入启动文件夹: $lnk" -ForegroundColor Green }
        else { Write-Host '    启动项创建失败，请手动执行一次 Keep-TyporaTrial.ps1' -ForegroundColor Yellow }
    }
}

# ---------- 额外：快捷方式 ----------
if ($FixShortcuts) {
    Write-Host "`n[额外] 处理 Typora 快捷方式 ..." -ForegroundColor Yellow
    $target = if ($Wrapper) { $openCmd } else { $TyporaExe }

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Typora\Typora.lnk'))
    $candidates.Add((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Typora.lnk'))
    $desk = [Environment]::GetFolderPath('Desktop')
    $candidates.Add((Join-Path $desk 'Typora.lnk'))
    Get-ChildItem $desk -Filter '*ypora*.lnk' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { $candidates.Add($_.FullName) }

    $ws = New-Object -ComObject WScript.Shell
    $done = 0
    foreach ($l in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path $l)) { continue }
        $bak = "$l.bak"
        if (-not (Test-Path $bak)) { Copy-Item $l $bak -Force }
        try {
            $sc = $ws.CreateShortcut($l)
            $sc.TargetPath       = $target
            $sc.Arguments        = ''
            $sc.WorkingDirectory = $root
            $sc.IconLocation     = "$TyporaExe,0"
            $sc.WindowStyle      = 7
            $sc.Description      = 'Typora'
            $sc.Save()
            Write-Host "    已改: $l" -ForegroundColor Green
            $done++
        } catch {
            Write-Host "    改失败: $l -> $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($done -eq 0) { Write-Host '    没找到可改的快捷方式（不影响主功能）' -ForegroundColor Yellow }
}

Write-Host "`n==== 完成 ====" -ForegroundColor Cyan
Write-Host '注意：正在运行的 Typora 仍带着旧状态，请完全退出后重新打开一次。' -ForegroundColor Magenta
Write-Host '验证：powershell -ExecutionPolicy Bypass -File .\verify.ps1' -ForegroundColor Magenta
