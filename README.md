# 萤光守护 · CyberSelfDiscipline

> 一个**完全本地运行**的数字健康 / 屏幕使用管理应用，使用 HarmonyOS ArkTS + ArkUI 构建。

[![License: GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-HarmonyOS%206-000000.svg)
![Tests](https://img.shields.io/badge/localunit-225%20passing-brightgreen.svg)
![API](https://img.shields.io/badge/API-23%2B-007AFF.svg)

---

## 简介

萤光守护帮助你把「屏幕使用」变成可感知、可管理的数字健康指标：

- 统计的是**整台手机的亮屏时长**（系统亮灭屏事件 + 解锁事件），而不是某一个应用的前台时长；
- 提供睡眠、专注、提醒、限额、免打扰、成就与每日目标等习惯工具；
- **不申请网络权限**，所有数据只保存在本机；支持手动导出/导入 JSON 备份。

> 应用不阻断手机使用，只做提醒与统计。

## 功能

- **真实亮屏统计**：订阅 `SCREEN_ON / SCREEN_OFF / SCREEN_UNLOCKED` + `power.isActive()` 轮询兜底，跨日自动结算，近 7 天趋势与解锁洞察。
- **睡眠守护**：睡前使用时长统计（可自定义统计窗口与提醒提前量）、睡眠目标、评分与改善建议，可同步华为运动健康数据。
- **番茄钟专注**：前台/后台持续计时、短/长休息、连击积分与会话统计，结束后自动接力护眼提醒。
- **健康提醒**：久坐 / 用眼 / 喝水三条可配置提醒 + 自定义提醒，统一以通知栏常驻通知呈现（可见下次触发时间）。
- **每日限额与免打扰**：三档预警（50% / 80% / 100%）、免打扰时段提醒（不阻断使用）。
- **外观与个性化**：跟随系统/浅色/深色；6 个预设强调色 + 任意 `#RRGGBB` 自定义强调色（自动按 WCAG AA 推导文本色与填充色）；首页卡片显示/排序/恢复默认；自定义称呼用于首页问候。
- **成就与每日目标**：14 枚成就实时解锁，打卡、连续天数、自定义目标与模板。
- **数据备份 / 恢复**：睡眠、限额、免打扰、专注、成就、解锁、提醒、每日目标全量 JSON 导出导入。
- **桌面卡片**：FormExtensionAbility 展示当日状态。
- **隐私优先**：首启隐私同意闸门；同意前不启动数据采集；无网络请求代码。

## 目录结构

```
.
├── AppScope/                  # 应用级配置与图标
├── entry/                     # 主模块
│   └── src/
│       ├── main/
│       │   ├── ets/
│       │   │   ├── entryability/        # UIAbility 入口
│       │   │   ├── managers/            # 22 个业务管理器（统计/睡眠/专注/提醒/备份…）
│       │   │   ├── models/              # 纯函数内核 + 共享类型（可单测）
│       │   │   ├── pages/               # 首页 / 睡眠 / 专注 / 设置 / 洞察 / 目标 / 成就…
│       │   │   ├── components/          # 玻璃卡、iOS26 主题、光晕、弹窗、提醒控件
│       │   │   └── widget/              # 桌面卡片
│       │   └── resources/
│       ├── test/                        # LocalUnit（本地纯函数单测，225 例）
│       └── ohosTest/                    # 设备测试（15 例）
├── docs/ARCHITECTURE.md      # 架构与模块说明
├── scripts/check-source.mjs  # 轻量源码检查（CI 使用）
└── .github/                  # Issue / PR 模板与 CI
```

## 技术栈

- HarmonyOS 6.1+（compileSdk / targetSdk / compatibleSdk 均为 `6.1.0(23)`，modelVersion `6.0.2`）
- ArkTS + ArkUI（声明式 UI、`@State`/`@Observed`/`@StorageProp` 状态管理）
- HDS 组件（`HdsNavigation` / `HdsTabs`）+ Liquid Glass 风格自绘
- 测试：Hypium（LocalUnit 离线、ohosTest 设备侧）

架构与数据流见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 构建

环境：DevEco Studio 6.x（含 HarmonyOS SDK 与内置 Node.js），Windows / macOS 均可。

```powershell
# 1. 安装依赖（首次必须；否则单测无法解析 @ohos/hypium）
ohpm install --all

# 2. 设置 SDK 环境（命令行构建需要）
$env:DEVECO_SDK_HOME = '<DevEco>/sdk'
$env:NODE_HOME       = '<DevEco>/tools/node'
$node    = '<DevEco>/tools/node/node.exe'
$hvigor  = '<DevEco>/tools/hvigor/bin/hvigorw.js'

# 3. 构建 HAP（debug）
& $node $hvigor assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug

# release
& $node $hvigor assembleHap --mode module -p module=entry@default -p product=default -p buildMode=release
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`。

> 仓库不包含签名材料（`.p12` / `.p7b` 等已在 `.gitignore` 中）。默认产出 **unsigned HAP**：
> 模拟器/开发者模式设备可直接安装；真机分发需自行配置签名。
> 安装：`hdc install -r entry-default-unsigned.hap`。

> 磁盘上的本地路径配置（`local.properties`）与 `oh_modules/` 不入库，由 DevEco/ohpm 生成。

## 测试

```powershell
# 本地单元测试（离线，无需设备）
& $node $hvigor test --mode module -p module=entry@default -p product=default -p buildMode=debug

# 设备测试（需模拟器/真机已连接）
& $node $hvigor assembleHap --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug
hdc install -r entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap
hdc shell aa test -b com.soviet.cyberselfdiscipline -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 120000 -w 120
```

- LocalUnit 结果以 `entry/.test/default/intermediates/test/coverage_data/test_result.txt` 末行为准。
  控制台偶尔出现 `getInitCoverageData failed, SyntaxError ...` 是该测试工具的已知缺陷，与代码无关。
- 当前基线：**LocalUnit 225 pass / 0 fail**；**ohosTest 15 pass / 0 fail**（HarmonyOS 模拟器）。

GitHub Actions 只运行轻量的源码检查（编码/JSON/许可证完整性），因为完整构建需要 DevEco SDK 与签名环境。

## 权限与隐私

应用声明的运行时权限：

| 权限 | 用途 |
|---|---|
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 后台长时任务：保持亮屏统计与常驻提醒存活 |
| `ohos.permission.READ_HEALTH_DATA` | 仅在用户主动点击「从华为运动健康同步」时读取睡眠数据 |

- **无网络权限**（`module.json5` 未声明 `INTERNET`），不存在上传通道。
- 数据保存在应用私有 Preferences 中；卸载即删除。
- 导出备份由用户通过系统文件选择器指定位置，文件由用户自行保管。
- 详细说明见应用内「隐私政策」页与 [SECURITY.md](SECURITY.md)。

## 已知限制

- 亮屏/解锁事件与 JS 定时器依赖进程存活：系统回收进程后，期间的数据与提醒会丢失（与“常驻通知”方案一致）。
- 未配置签名，只能产出 unsigned HAP。
- 部分 UI 自动化/截图验证依赖模拟器；模拟器无法修改系统时间，跨日/跨午夜逻辑以纯函数单测为准。
- 通知栏常驻通知依赖系统通知总开关；关闭后提醒不可见。

## 贡献

欢迎 Issue / PR。请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

- 修改纯逻辑时，优先把计算搬进 `entry/src/main/ets/models/` 并补 LocalUnit 用例；
- 不要提交个人路径、设备标识、签名材料或任何密钥；
- PR 请附构建/测试结果（命令与关键输出）。

## 许可证

本项目以 **GNU General Public License v3.0 only**（GPL-3.0-only）发布，见 [LICENSE](LICENSE)。

第三方依赖（`@ohos/hypium`、`@ohos/hamock` 等）遵循其各自许可证，仅用于开发与测试。

---

## English

**CyberSelfDiscipline** ("Firefly Guard") is a fully offline digital-wellbeing app for HarmonyOS.
It measures **device screen-on time** (not per-app foreground time), and provides sleep tracking,
Pomodoro focus, configurable break reminders, daily limits, downtime reminders, achievements,
daily goals, home-screen card customization and local JSON backup — **with no network permission
and all data kept on-device**.

Built with ArkTS / ArkUI (HarmonyOS 6.1+, API 23). Licensed under GPL-3.0-only. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the module layout and build/test instructions above.
