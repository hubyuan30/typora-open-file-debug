# 根因分析

## 主进程入口链

```text
resources/app.asar
  └─ package.json          main = "launch.dist.js"
      └─ launch.dist.js      1383 B 纯 JS 加载器
          └─ atom.compiled.dist.jsc   379120 B V8 cached-data 字节码
```

授权判定、打开文件、单实例处理这些逻辑全在 `atom.compiled.dist.jsc` 里，
是 V8 的 cached-data 字节码，不是明文 JS。字符串常量仍是明文的
（能搜到 `sha256`、`digest`、`checksum failed` 之类），但控制流看不到。

## 单实例机制

Electron 的 `app.requestSingleInstanceLock()` 让第二个进程拿不到锁，
它把命令行交给主进程，然后自己退出：

```text
第二个进程
  → requestSingleInstanceLock() 返回 false
  → 主进程收到 second-instance 事件
      → App.openFileOrFolder(argv)
          → 判断授权状态
              ├─ 有授权 / 试用期有效 → 正常加载文件
              └─ 试用过期且无授权   → showLicensePanel()
                                        → 面板对象已销毁
                                        → TypeError: Object has been destroyed
                                        → 异常向上抛，后续 load 语句被跳过
```

关键点：`showLicensePanel()` 里访问了一个已经不存在的窗口对象。
在**首次启动**（一级实例）时路径不同 —— 那时面板是刚创建的，所以不抛异常。
只有二级实例这条路径会拿到陈旧引用。

## 触发条件（三者同时成立）

1. `SLicense` 为空、日志 `hasL: false`
2. `trailRemains = 0`（试用已过期）
3. 从二级实例打开文件

## 修复策略对比

| 策略 | 做法 | 可行性 |
| --- | --- | --- |
| 掐掉条件 2 | 让 `trailRemains = 15` | ✅ 本项目方案，不碰程序文件 |
| 修 bug 本体 | 改 jsc 里 `showLicensePanel` 的判空 | ❌ 字节码，且撞 asar 完整性校验 |
| 让条件 3 不成立 | 每次打开都先完全退出再启动 | ❌ 体验不可接受 |

选第一种：`trailRemains = 15` 时 `openFileOrFolder` 判定"还在试用期"，
根本不会调用 `showLicensePanel()`，那个坏引用也就永远不会被访问。

## 日志证据位置

`%APPDATA%\Typora\typora.log`

关键行：

```text
[L] installDate is <日期>, trail remains: 15 days
[watch L] hasL: false
got argv [...] from secondary instance
unhandledRejection TypeError: Object has been destroyed
  at Object.ea [as showLicensePanel]  (atom.compiled.dist.jsc:1:63328)
  at App.openFileOrFolder             (atom.compiled.dist.jsc:1:228863)
readContentFrom <路径>
```
