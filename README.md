# Windows 笔记本屏幕亮度无法调节：排查与修复

> **一句话结论：先查 `NvContainerLocalSystem` 服务有没有被禁用。**
> 这个服务被"优化软件"关掉后，亮度滑块和 Fn 亮度键会全部失效，而设备管理器里一切正常、驱动版本也没问题。
> 修复只需三条命令，不用重装驱动，不用重启。

---

## 症状

- 设置 → 系统 → 显示 里的亮度滑块能拖动，但屏幕亮度不变
- F 区带太阳图标的亮度键按了没有任何反应，也没有 OSD 提示
- NVIDIA 控制面板打不开（右键桌面没有该选项，或点击无反应）
- 设备管理器里显卡状态正常，没有黄色感叹号
- 重启、重装驱动、更新 BIOS 均无效

## 复现环境

| 项目 | 值 |
|---|---|
| 机型 | Dell G16 7620 |
| 显卡 | Intel Iris Xe（核显）+ NVIDIA RTX 3060 Laptop（独显） |
| 显示模式 | Hybrid / Optimus（独显直连关闭） |
| 系统 | Windows 11 Build 26200 |
| 触发原因 | 第三方"清理/优化"软件把 NVIDIA 服务设为禁用 |

原理上不限于 Dell，任何 **NVIDIA 双显卡笔记本**都可能中招。

---

## ⚠️ 先说一个坑：WMI 亮度接口的正确读法

排查时最容易被误导的地方。`root\wmi` 下的 `WmiMonitorBrightness` 类有两个极易混淆的属性：

```powershell
$b = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness

$b.Level    # uint8[]  → 真正的档位数组，正常是 0,1,2,...,100
$b.Levels   # uint32   → 档位的【数量】，正常是 101
```

**很多人（包括不少脚本和 AI 助手）会去读 `Levels`，看到值是 `101`、`Count` 是 `1`，就断定"亮度接口只剩一个档位、接口坏了"。这是错的。**

- `Levels` 的值 `101` 表示"共 101 个档位"
- `Level` 才是数组，`Level.Length` 才是有意义的检查值

判断亮度接口是否正常，只认这一条：

```powershell
(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness).Level.Length
# 101 = 接口正常；0 或 1 = 接口异常
```

本例中该值始终是 `101`，接口一直是好的——问题根本不在这一层。

---

## 完整的排查路径（含我们走过的弯路）

### ❌ 误判 1：Intel 显卡驱动

现象符合"核显驱动挂了导致亮度失效"的经典症状，于是重装 / 降级 Intel 显卡驱动。

**结果：无效。** 亮度完全没变化。

### ❌ 误判 2：`FeatureTestControl` 注册表值

网上流传的 Dell 亮度修复方案，把下面这个值从 `0x1200` 改成 `0x9240`（37440）：

```
HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001
  FeatureTestControl  REG_DWORD
```

**结果：无效。** 改完重启设备、改完重启系统，亮度依旧不可调。

### ❌ 误判 3：重启显示适配器

```powershell
pnputil /restart-device "<显卡实例ID>"
```

**结果：单独执行无效。** 这一步本身没错，但它必须配合下面那一步才有意义。

### ❌ 误判 4：BIOS 独显直连

Dell 官方支持建议进 BIOS 检查 `Display → Hybrid` 是否开启。本例中一直是开启状态，排除。

---

## ✅ 真正的原因：`NvContainerLocalSystem` 被禁用

查一下这个服务：

```powershell
Get-Service NvContainerLocalSystem | Select-Object Status, StartType
```

本例的输出：

```
Status   StartType
------   ---------
Stopped  Disabled
```

**`Disabled` 就是元凶。**

### 为什么是它

`NvContainerLocalSystem`（NVIDIA LocalSystem Container）是 NVIDIA 驱动栈的常驻容器服务，负责显示相关的底层任务调度。在 **Optimus 混合显卡**机型上，内屏亮度控制需要它参与链路；一旦被禁用：

1. 内核驱动（`nvlddmkm.sys`）本身正常加载 → 设备管理器无异常，驱动版本显示正常
2. 但用户态的显示控制链路断了 → 亮度 API 写入被"接受"却不落到背光上
3. NVIDIA 控制面板依赖同一个容器 → 打不开

这就是为什么**所有"看驱动版本、看设备状态"的排查都会得出"一切正常"的错误结论**。

### 谁把它禁用的

"清理/优化/加速"类软件（例如 `wincleaner.exe` 之类）。它们把 NVIDIA 服务设为禁用以减少开机占用，副作用就是亮度控制和显卡控制面板一起废掉。这类软件往往还会顺手装错驱动——本例机器上就残留着联想笔记本的 ACPI 幽灵设备。

---

## 修复

必须管理员权限。三条命令：

```powershell
# 1. 恢复为自动启动
Set-Service NvContainerLocalSystem -StartupType Automatic

# 2. 启动服务
Start-Service NvContainerLocalSystem

# 3. 重载 NVIDIA 显示驱动（屏幕会闪一下，正常）
pnputil /restart-device "PCI\VEN_10DE&DEV_2560&SUBSYS_0B991028&REV_A1\4&36B971D5&0&0008"
```

第 3 步的实例 ID 每台机器不同，用这个自动取：

```powershell
(Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -like '*NVIDIA*' }).InstanceId
```

或者直接跑仓库里的脚本（自动检测、自动提权）：

```powershell
.\scripts\Fix-Brightness.ps1
```

**效果：本机执行完第 3 条命令后，亮度立即恢复，无需重启。**

> 注意：PowerShell 里 `sc` 是 `Set-Content` 的别名，写 `sc config ...` 会把命令吃掉且不报错。要用 `sc.exe`。

---

## 验证

```powershell
# 服务应为 Running / Auto
Get-Service NvContainerLocalSystem | Select-Object Status, StartType

# 亮度接口应为 101
(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness).Level.Length
```

最终确认标准只有一个：**拖动亮度滑块，屏幕亮度真的跟着变。**

---

## 防止复发

1. **卸载或永久关闭清理/优化类软件**，至少在它们的"服务优化"列表里把 `NvContainerLocalSystem` 和 `NVDisplay.ContainerLocalSystem` 加入白名单
2. **不要用 NVIDIA App / GeForce Experience 自动更新驱动**（双显卡笔记本优先用厂商定制版驱动）
3. 亮度再次失灵时，第一条命令永远是：

```powershell
Get-Service NvContainerLocalSystem | Select-Object Status, StartType
```

看到 `Disabled` 就是它，不必重装驱动。

---

## 诊断速查表

按顺序执行，`Diagnose-Brightness.ps1` 会一次性输出全部结果。

| # | 检查项 | 命令 | 正常值 |
|---|---|---|---|
| 1 | 亮度档位数组 | `(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness).Level.Length` | `101` |
| 2 | NVIDIA 容器服务 | `Get-Service NvContainerLocalSystem` | `Running` / `Automatic` |
| 3 | NVIDIA 显示服务 | `Get-Service NVDisplay.ContainerLocalSystem` | `Running` / `Automatic` |
| 4 | 显卡设备状态 | `Get-PnpDevice -Class Display` | 全部 `OK` |
| 5 | 内屏连接方式 | `Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams` | `0x80000000`（内置屏） |
| 6 | 自适应亮度 | `powercfg /query SCHEME_CURRENT SUB_VIDEO` 中的 `ADAPTBRIGHT` | AC/DC 均为 `0`（关闭） |

如果第 2 项是 `Disabled`，直接跳到[修复](#修复)。如果第 1 项不是 `101`，那是另一类问题（显示器驱动 / 显卡驱动），不在本文范围。

---

## 常见误诊清单（别浪费时间）

| 做法 | 有效？ | 说明 |
|---|---|---|
| 重装 / 降级 Intel 显卡驱动 | ❌ | 本例实测无效 |
| 改 `FeatureTestControl` 为 `0x9240` | ❌ | 本例实测无效 |
| 单独执行 `pnputil /restart-device` | ❌ | 服务被禁用时重载也没用 |
| 检查 BIOS 独显直连 | ❌ | 本就是 Hybrid 模式，正常 |
| 更新 BIOS | ❌ | 与用户态服务无关 |
| 重启系统 | ❌ | 服务启动类型是 Disabled，重启后依然不启动 |
| **启用 `NvContainerLocalSystem` + 重载驱动** | ✅ | 立即生效 |

---

## English summary

**Symptom:** The brightness slider and brightness hotkeys do nothing on a Windows laptop. Device Manager, driver version and the WMI brightness interface all look perfectly healthy.

**Root cause:** The `NvContainerLocalSystem` service (NVIDIA LocalSystem Container) was set to `Disabled` — usually by a third-party "cleaner/optimizer" tool. On Optimus/hybrid-graphics laptops this breaks the user-mode display control path, so brightness writes are accepted but never reach the backlight.

**Fix:** Set the service back to `Automatic`, start it, then reload the NVIDIA display device. No reboot, no driver reinstall.

**Gotcha:** `WmiMonitorBrightness.Levels` is the *count* of levels (101), not the array. The array is `Level`. Checking `Levels.Count` gives `1` and leads to a completely wrong diagnosis. Always check `Level.Length`.

---

## License

MIT
