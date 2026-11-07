# Explorer 句柄泄漏：根因与处置

> 适用：Windows 11（23H2 / 24H2 / 更高版本）资源管理器句柄持续增长、内存提交量暴涨
> 结论性质：**微软自身的代码缺陷**，非第三方软件、非硬件问题

---

## 一、一句话结论

`explorer.exe` 的 **XAML 命令栏（资源管理器顶部工具栏）在构建每个菜单项时，
会打开 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CommandStore`
下的注册表键句柄，但因为一处 COM 引用计数漏减，这个句柄永远不会被关闭。**

每重建一次命令栏就漏一个。窗口开得越久、重建次数越多，句柄越多，
最终表现为句柄数十万级、提交内存按 GB 增长、explorer 多线程空转。
关掉窗口不释放，只有结束 explorer 进程才能回收。

---

## 二、怎么判断自己遇上了

三个特征同时出现，基本可以确诊：

| 特征 | 观察方法 | 典型值 |
|---|---|---|
| 句柄总量异常 | 任务管理器 → 详细信息 → 添加「句柄」列 | 正常 2,000~6,000；泄漏时数万到数十万 |
| 泄漏的几乎全是 `Key` 类型 | `Get-Process explorer` + 句柄类型统计工具 | `Key` 占比 > 95% |
| 泄漏速率随窗口可见性变化 | 开窗 / 最小化 / 关闭三态对照 | 可见时每分钟数千，最小化后个位数 |

反向验证：**重启 explorer 后归零，只开一个普通文件夹窗口时几乎不增长，
把窗口连续开几分钟则快速上涨**——这就是渲染路径的问题，不是后台服务。

---

## 三、根因（代码级）

社区已有完整逆向分析（2025 年在 23H2 / 24H2 复现），后续版本实测栈一致，
说明至今未修。调用链：

```
FileExplorerExtensions.dll!CommandBarControl::CommandBarControl
  → CommandBarControlVM::GetCommandBarItemVMs
  → Windows.UI.FileExplorer.dll!GetCanonicalCommand
  → windows.storage.dll!CCommandStore::GetCanonicalCommand
  → windows.storage.dll!RegDataDrivenCommand::SetKeyAndName
  → shlwapi.dll!QuerySourceCreateFromKey
  → RegOpenKeyExW                    ← 打开 CommandStore，此后永不 CloseHandle
```

缺陷点（反编译还原，示意）：

```c
unsigned long long GetCommand(void* this, winrt::impl* impl, MenuItem* CoMenuItem)
{
  struct MenuItem tmp;
  winrt::hstring* tmphstring = GetCommand(this - 40, &tmp, &impl);
  *CoMenuItem = tmphstring;
  *tmphstring = NULL;              // ← 把 tmp 一并清零
  if (tmp)                         // ← 于是永远为假
    unconditional_release_ref(&tmp);   // ← 永远执行不到
  return NULL;
}
```

`GetCommand()` 直接把自己的第二个参数原样返回，`tmphstring` 与 `&tmp` 指向同一块内存。
一旦 `*tmphstring = NULL`，`tmp` 就被清零，后面那次 `Release()` 成了死代码。

结果：`FileExplorerMenuItem`（内部持有 `RegDataDrivenCommand` 打开的 HKEY）
少减一次引用 → 该 COM 对象永远不会析构 → HKEY 永远不关。

作者也验证过「强行 Release 会 heap corruption」，所以这不是「忘了关句柄」，
而是引用计数逻辑本身写错，必须微软改代码才能修。

### 为什么会失控

1. 泄漏对象一直活着，不会被回收；
2. 命令栏每次重建都要遍历/解析这些命令对象，**对象越多，单次重建越慢**；
3. 界面刷新是持续的，重建不会停 → 每次重建再漏一个 → 对象更多；
4. 到几十万句柄时，shell 几乎无法完成一次完整布局，多个线程持续重试，
   CPU 被占满。

---

## 四、已排除的嫌疑（避免误伤）

| 嫌疑对象 | 判定 | 依据 |
|---|---|---|
| 安全软件 / 杀软的 API hook 层 | 无关 | 任何注册表调用都会路过其跳板，出现在栈上属正常；热栈主体是纯微软模块 |
| 版本控制外壳扩展（Tortoise 系） | 无关 | 多次采样的热栈里从未出现 |
| 办公 / 输入法 / 网盘 / 压缩软件的 shell 扩展 | 无关 | 干净重启后仅开窗口也会复现 |
| 内存条 / 页面文件 | 无关 | 问题在提交量而非物理占用 |
| 多套 Electron 应用 | 另一回事 | 它们占用的是「基数」，不会随窗口可见性增长 |

---

## 五、处置

### 5.1 立即恢复：重启 explorer

结束并重启 `explorer.exe` 可一次性回收全部泄漏句柄（桌面会闪一下，不影响已保存的工作）。
处置后应满足：句柄数 < 10,000、增长速率 < 100/分钟、explorer CPU < 5%。

### 5.2 短期：守护脚本

```powershell
powershell -ExecutionPolicy Bypass -File scripts\13-explorer守护.ps1 -Status
powershell -ExecutionPolicy Bypass -File scripts\13-explorer守护.ps1 -Restart
powershell -ExecutionPolicy Bypass -File scripts\13-explorer守护.ps1 -Install
powershell -ExecutionPolicy Bypass -File scripts\13-explorer守护.ps1 -Uninstall
```

判定阈值：explorer 句柄数 > 30,000（正常 2,000~6,000），冷却 4 小时。
有文件操作在进行时脚本会自动放弃重启。日志在 `logs\explorer-guard.log`。

### 5.3 结构性缓解：每个文件夹窗口独立进程

「文件夹选项 → 查看 → 在单独的进程中打开文件夹窗口」（等价于守护脚本的 `-SeparateProcess`）。
每个窗口一个 explorer.exe，关掉窗口就等于回收该窗口的全部泄漏。

**有取舍**：长期挂着多个窗口时，会变成多个各自泄漏、各自空转的进程，
任务管理器更难看。建议按习惯选：

| 习惯 | 建议 |
|---|---|
| 用完就关窗口 | 开独立进程，收益明显 |
| 长期挂十几个窗口 | 不开，用守护脚本兜底 |

### 5.4 成本最低的两条使用习惯

1. 不用的资源管理器窗口及时最小化或关掉——泄漏速率会直接掉到个位数；
2. 别让窗口连续挂几天——泄漏只在窗口可见时累积。

### 5.5 根本解决

- **Windows 10 没有这套 XAML 命令栏**：`Windows.UI.FileExplorer.dll` /
  `FileExplorerExtensions.dll` 在 Win10 里不存在，换 Win10 即无此问题。
- 留在 Win11 只能等微软修。最新累积更新实测仍未修。
- 不建议内存补丁（nop 掉 `*tmphstring = NULL`）：无签名二进制修改会被安全软件拦截，
  且每次累积更新偏移都会变，维护成本高于收益。

---

## 六、复现与验收

```powershell
# 看现状
powershell -ExecutionPolicy Bypass -File scripts\13-explorer守护.ps1 -Status

# 复现（可选）：开 3~5 个资源管理器窗口，放 3 分钟，再看 -Status
# 泄漏会以每分钟数千的速度上涨；最小化窗口后应立刻掉到个位数

# 验收：处置后应满足
#   句柄数 < 10,000，速率 < 100/分钟，explorer CPU < 5%
```

---

## 七、附：取证手法（可复用）

| 目的 | 手法 |
|---|---|
| 按类型统计句柄 | `NtQuerySystemInformation(SystemExtendedHandleInformation=64)`；64 位句柄必须把 `OpenProcess` 的 restype 声明为 `HANDLE`，否则被截断成 32 位 |
| 取句柄指向的对象名 | `DuplicateHandle` 到自己进程后 `NtQueryObject(ObjectNameInformation=1)`，必须放子线程加超时，否则命名管道会挂死 |
| 找热点线程 | `GetThreadTimes` 采两次算增量，再 `NtQueryInformationThread(9)` 取起始地址 |
| 抓调用栈 | `SuspendThread` + `GetThreadContext`（CONTEXT AMD64：RSP@0x98 / RBP@0xA0 / RIP@0xF8，ContextFlags@0x30），`ReadProcessMemory` 扫栈上落在模块区间内的返回地址，立刻 `ResumeThread` |
| 判定泄漏归属 | 关窗口 / 最小化 / 重启进程三态对照，看速率是否随可见性变化 |
