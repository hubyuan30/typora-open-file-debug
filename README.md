# Typora 已开一个 md 后双击新 md 打不开：一次 Electron 主进程崩溃的根因定位

> 环境：Typora 1.12.1 / Electron 35.6.0 / Windows 11 (26100)
> 最后验证：2026-11-23

## TL;DR

Typora 在「试用已过期 + 未激活」状态下，通过**二级实例**打开文件会走：

```
App.openFileOrFolder → showLicensePanel()
```

而那个授权面板的窗口对象已经被销毁，于是抛 `TypeError: Object has been destroyed`，
异常打断了后面的加载语句 —— 文件根本没被读入。

**现象**：已开一个 md，去资源管理器双击另一个 md，毫无反应；必须先关掉当前窗口才行。

**绕开方式**：把试用起点（`profile.data` 里的 `_iD`）维持为当天，让 `trailRemains` 恒为 15，
就不再进入授权面板分支。**不需要修改 Typora 的任何程序文件** ——
Typora 1.12 带 SHA256 自校验，动 `app.asar` 会直接以 `Integrity check failed` 退出。

---

## 1. 现象与触发条件

| 场景 | 结果 |
| --- | --- |
| Typora 未运行 → 双击 md | ✅ 正常 |
| Typora 已运行 → 程序内 `Ctrl+O` | ✅ 正常 |
| Typora 已运行 → 资源管理器双击另一个 md | ❌ 打不开 |

只有「二级实例转发」这一条路径坏掉。这张表本身就是线索。

触发需要三个条件同时成立：

1. 无授权（`SLicense` 为空，日志里 `hasL: false`）
2. 试用已过期（`trailRemains = 0`）
3. 从二级实例打开文件

---

## 2. 证据：调用栈已经把因果写明白了

Typora 的日志在 `%APPDATA%\Typora\typora.log`。复现一次，得到：

```text
INFO  got argv [Typora.exe, --allow-file-access-from-files, --no-sandbox, <b.md>] from secondary instance
INFO  secondary instance would exit
ERROR unhandledRejection TypeError: Object has been destroyed
        at Object.ea [as showLicensePanel]  (atom.compiled.dist.jsc:1:63328)
        at App.openFileOrFolder             (atom.compiled.dist.jsc:1:228863)
```

统计一段时间内的日志：**10 次二级实例打开，7 次抛这个异常，`readContentFrom` 一次都没出现**。
也就是说文件从未被读进渲染进程，用户看到的"没反应"是真的什么都没发生。

`openFileOrFolder` 里先判断授权状态，判定不通过就去 `showLicensePanel()`，
一旦抛异常，后面的加载语句全部跳过。

> 注意：那 3 次没抛异常的，是当时试用状态恰好还没过期，属于同一机制的正面样本。

---

## 3. 为什么「关掉再开」就好了

- 关闭窗口 = 进程退出 = 那个"已销毁的面板引用"随内存一起消失
- 新进程启动时面板是新建的、活的，`show()` 不再抛异常，流程走完

所以这个 bug 的表现是"每次会话只坏一次，重启就好"，很容易被误判成偶发故障。

---

## 4. 试用状态到底存在哪

这一层花了点工夫，因为有两个疑似位置：

| 位置 | 内容 |
| --- | --- |
| `HKCU\SOFTWARE\Typora\IDate` | 注册表里的日期字符串 |
| `%APPDATA%\Typora\profile.data` 的 `_iD` 字段 | 配置里的日期字符串 |

做对照实验：

| 改了什么 | 日志表现 |
| --- | --- |
| 只改注册表 `IDate` | `IDate : 11/23/2026` 但 `trail remains: 0` ❌ |
| 只改 `profile.data._iD` | `trail remains: 15 days` ✅ |
| 两个都改 | 15 天，且两处一致 |

**结论：真正参与判定的是 `profile.data._iD`，注册表那份只是副本。**
只改注册表是没有用的。

另一个坑：`profile.data` 不是明文 JSON，而是 **hex 编码的 UTF-8 JSON**。
直接文本编辑会把它弄坏，必须走「解码 → 改字段 → 重编码」。
它存的字段很多（主题、缩放、自动保存、窗口位置等），改写时要保持其余字段不变。

---

## 5. 想直接改程序？先过 SHA256 完整性清单

`resources/app.asar` 只有 3 个条目：

```text
atom.compiled.dist.jsc   379,120 B   V8 cached-data 字节码，授权逻辑在这里
launch.dist.js             1,383 B   入口加载器
package.json                 251 B   main 指向 launch.dist.js
```

asar 容器格式：

```text
uint32(4) | uint32(headerLen) | uint32(payloadLen) | uint32(jsonLen) | json | pad4 | data
```

数据区起始偏移是 **800**（4 字节对齐；按 797 会错 3 字节，解出来的文件末尾会缺一点）。

每个文件条目带一份完整性清单：

```json
{"size":1383,"offset":"379120",
 "integrity":{"algorithm":"SHA256","hash":"...","blockSize":4194304,"blocks":["..."]}}
```

实验矩阵详见 [docs/asar-integrity.md](docs/asar-integrity.md)，结论是：

- 文件**内容**不校验 —— 原地改一个字节，程序照常启动
- 但 asar **头/清单**一改就 `Integrity check failed` 直接退出
- 所以"解包 → 改 → 重新打包"这条路是走不通的，只剩「头逐字节不变 + 同长度原地替换」这一条窄缝

顺带发现一个有意思的细节：头里声明的 jsc hash 与文件实际 hash **不一致**
（`2f69400a…` vs `9941c26e…`），而校验放行了它 —— 说明校验只针对特定条目，不是全量。

---

## 6. 修复方案

思路：不修 bug，而是让触发条件 2 永不成立。

### 6.1 安装

```powershell
# 无黑窗模式（推荐）
powershell -ExecutionPolicy Bypass -File .\scripts\Install-TyporaFix.ps1

# 若自动探测不到 Typora，显式指定
powershell -ExecutionPolicy Bypass -File .\scripts\Install-TyporaFix.ps1 -TyporaExe "D:\Apps\Typora\Typora.exe"

# 每次打开前都刷新（代价：双击时短暂 cmd 黑窗）
powershell -ExecutionPolicy Bypass -File .\scripts\Install-TyporaFix.ps1 -Wrapper
```

安装脚本做了四件事，**全部在用户态**：

| # | 改动 | 可逆性 |
| --- | --- | --- |
| 1 | 立即执行一次保活，把 `_iD` 刷成当天 | 有 `profile.data.bak` |
| 2 | `.md` 关联指向 `Typora.exe`（或包装器） | 有 `association-backup.txt` |
| 3 | 建登录触发（计划任务，失败则退化为启动文件夹） | 一条命令删除 |
| 4 | 可选：`-FixShortcuts` 顺带处理快捷方式 | 原 `.lnk` 备份为 `.lnk.bak` |

**一个字节都不动**：Typora 安装目录里的所有文件。
也不碰 `UserChoice`（那个键带 Windows 的校验哈希，硬改会让"默认应用"被系统重置）。

### 6.2 验证

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

预期输出：

```
profile._iD      = 11/23/2026
✓ 已是今天
关联: "D:\Apps\Typora\Typora.exe" "%1"
启动文件夹项 = True
最近出现授权面板崩溃 = 否
```

再看一眼 Typora 日志，应该有：

```text
[L] installDate is 11/23/2026, trail remains: 15 days
```

### 6.3 回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Remove-TyporaFix.ps1
# 连试用状态一起还原
powershell -ExecutionPolicy Bypass -File .\scripts\Remove-TyporaFix.ps1 -RestoreProfile
```

---

## 7. 行为边界（诚实列出）

| 场景 | 结果 |
| --- | --- |
| 已开一个 md，再双击新 md | ✅ 修好 |
| 连开十个 md 来回切 | ✅ |
| 从快捷方式 / 开始菜单启动 Typora | ✅（脚本已刷新过状态） |
| 开机后连续 **超过 15 天** 不注销不重启 | ⚠️ 状态过期，重启一次即恢复 |
| 重装或升级 Typora | ⚠️ 文件关联会被重置，重跑安装脚本即可 |
| 系统时间被回拨 | ⚠️ 天数计算异常，重启一次保活脚本即修正 |
| 你哪天真的激活了 | ✅ 无害冗余 |

---

## 8. 踩坑清单

详见 [docs/pitfalls.md](docs/pitfalls.md)。最容易中的几个：

1. **`cmd` 批处理里写中文注释** —— GBK 系统按 OEM 码页解析 UTF-8，把注释片段当命令执行，整个脚本静默失效
2. **用"日志新增行数"判断测试结果** —— Typora 会轮转 `typora.log`，行号错位导致误判成败
3. **单实例共享 `userData`** —— 测试实例会被转发到你正开着的进程，结论不可信；测试前必须全部退出
4. **`$PSScriptRoot` 写在 `param()` 默认值里** —— 取不到值，要在脚本体里解析
5. **`.ps1` 存成 UTF-8 无 BOM** —— Windows PowerShell 5.1 按 ANSI 读，中文注释导致解析崩

---

## 9. 未解决的问题

- **校验锚点在哪**：不在 asar 头、不在 `lib.asar`、不在 `node_modules.asar`、不在 `window.html`，也不在 jsc 的明文字符串常量里
- **同长度原地替换**（实验 F）还没拿到干净结论 —— 当时的测试被日志轮转污染了

欢迎补充线索。

---

## 10. 文件说明

```text
scripts/
├─ Keep-TyporaTrial.ps1   保活：刷 _iD + 同步注册表
├─ Install-TyporaFix.ps1  安装：关联 + 登录触发 + 可选快捷方式
├─ Remove-TyporaFix.ps1   回滚
├─ TyporaOpen.cmd         包装器（纯 ASCII，供 -Wrapper 模式用）
└─ verify.ps1             自检
docs/
├─ root-cause.md          根因分析
├─ asar-integrity.md      asar 完整性校验实验矩阵
└─ pitfalls.md            踩坑清单
```

## License

MIT
