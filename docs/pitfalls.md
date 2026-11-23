# 踩坑清单

这次排查踩到的坑，按"坑一次损失多少时间"排序。

## 1. `cmd` 批处理里写中文注释 → 整个脚本静默失效

Windows 中文系统默认 OEM 码页是 GBK(936)。`.cmd` 文件若存成 UTF-8，
cmd.exe 会按 GBK 逐字节解析，多字节字符被切错，注释片段被当成命令执行：

```text
'开包装器' is not recognized as an internal or external command
'自动跳过）' is not recognized as an internal or external command
```

更糟的是 `@echo off` 之后这些错误不一定显式报出来，表现是
"包装器跑了但什么都没发生"，很难定位。

**对策**：`.cmd` 文件一律保持纯 ASCII。注释用英文。
本项目的 `TyporaOpen.cmd` 就是纯 ASCII。

验证方法：

```powershell
$bytes = [System.IO.File]::ReadAllBytes('TyporaOpen.cmd')
($bytes | Where-Object { $_ -gt 127 }).Count -eq 0   # 应为 True
```

## 2. 用"日志新增行数"判断测试结果 → 误判

一开始的测试逻辑是：

```powershell
$before = (Get-Content $log).Count
# ... 做操作 ...
Get-Content $log | Select-Object -Skip $before     # 只看新增行
```

问题：Typora 会**轮转** `typora.log`。轮转后文件行数变少，
`Skip $before` 把所有行都跳过了，于是"没有新行"被误判成"操作失败"。

**对策**：不要用行号定位，改用**匹配关键行**：

```powershell
Get-Content $log -Encoding UTF8 -Tail 400 |
    Where-Object { $_ -match 'trail remains|readContentFrom|Object has been destroyed' }
```

## 3. 单实例共享 `userData` → 测试实例互相劫持

想用独立配置目录做隔离测试，试过设 `$env:APPDATA`。

**失败原因**：Electron 取 `userData` 走的是 Win32 API（`SHGetFolderPath`），
不读环境变量。所以测试实例和真实实例**用的是同一个配置目录、同一把单实例锁**。

后果：你以为在测隔离副本，实际上文件打开请求被转发到了你自己正开着的 Typora 进程，
日志里出现了完全无关的内容，结论自然是错的。

**对策**：任何涉及单实例的测试，先确认所有 Typora 进程都已退出。

```powershell
Get-Process Typora -ErrorAction SilentlyContinue | Select-Object Id, Path
```

清理时也要**按进程路径**过滤，不要盲目 `Stop-Process -Name Typora` ——
那会连你自己正在用的窗口一起杀掉。

## 4. `$PSScriptRoot` 写在 `param()` 默认值里 → 拿不到值

```powershell
# 错误写法
param([string]$LogFile = (Join-Path $PSScriptRoot 'keep.log'))
```

`param()` 默认值求值时 `$PSScriptRoot` 还没赋值，得到空串，
于是 `Join-Path` 报错：

```text
Join-Path : Cannot bind argument to parameter 'Path' because it is an empty string.
```

**对策**：在 `param()` 之后、脚本体里解析：

```powershell
param([string]$LogFile)
$baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $LogFile) { $LogFile = Join-Path $baseDir 'keep.log' }
```

## 5. `.ps1` 存成 UTF-8 无 BOM → PS 5.1 按 ANSI 读，解析崩

Windows PowerShell 5.1 对**无 BOM** 的文件按当前 ANSI 码页（GBK）解释。
文件里的中文注释就变成了乱码字节，可能正好构成未闭合的引号或括号，报：

```text
Try statement is missing its Catch or Finally block
字符串缺少终止符
```

**对策**：所有含中文的 `.ps1` 保存为 **UTF-8 with BOM**：

```powershell
$c = Get-Content $f -Raw -Encoding UTF8
[System.IO.File]::WriteAllText($f, $c, (New-Object System.Text.UTF8Encoding($true)))
```

> PowerShell 7 默认按 UTF-8 读，不受影响 —— 所以同一个脚本可能"在 pwsh 里正常、
> 在 powershell.exe 里报错"，很容易迷惑。

验证：

```powershell
& powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw 'x.ps1'))"
```

## 6. asar 解包偏移算错 3 字节

按 `4 + 4 + 4 + 4 + jsonLen` 算数据起始偏移，得到 797，实际是 **800**。

差 3 字节的后果很隐蔽：文件能解出来，但末尾缺一点，
`launch.dist.js` 断在语句中间，看起来像"文件损坏"而不是"偏移错了"。

**对策**：数据区起始要按 4 字节对齐：

```powershell
$dataStart = 16 + $headerLen
if ($dataStart % 4 -ne 0) { $dataStart += 4 - ($dataStart % 4) }
```

## 7. 计划任务需要管理员权限

`Register-ScheduledTask` 在本机返回 `Access is denied`，
`schtasks /Create` 同样失败。

**对策**：退化为**启动文件夹**方式，效果等价（登录时触发一次），且不需要提权：

```powershell
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'TyporaTrialKeep.lnk'
```

安装脚本已经内置了这个 fallback。

## 8. 打包应用的 `NODE_OPTIONS=--require` 无效

想用 `NODE_OPTIONS=--require=probe.js` 注入探针，完全没有日志。

**原因**：Electron 打包后的应用会忽略 `NODE_OPTIONS` 里的 `--require`。

**其他试过也失败的**：在 `resources\` 下放一个空的 `app\` 目录 ——
Electron 只认 `app.asar`，发现 `app\` 不完整就直接退出。
