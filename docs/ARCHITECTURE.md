# 架构说明

本文档描述代码分层、数据流、定时器与测试策略，便于二次开发。

## 分层

```
entry/src/main/ets/
├── entryability/EntryAbility.ets   # 应用入口：初始化 Preferences/Manager、发布主题、隐私闸门
├── pages/                          # 页面（Index 承载 4 个 Tab：首页/专注/睡前/设置）
│   ├── components/HomeCards.ets    # 9 张首页卡片（@Observed 数据驱动）
│   └── …                           # 洞察 / 目标 / 成就 / 隐私政策（路由压栈页）
├── components/                     # 通用 UI（GlassCard、iOS26Theme、AmbientLight、DialogShell…）
├── managers/                       # 业务与设备交互（22 个文件）
├── models/                         # 纯函数内核 + 共享类型（可单测，13 个文件）
└── widget/                         # 桌面卡片（FormExtensionAbility）
```

依赖方向固定为 **pages/components → managers → models**；`models/` 不依赖任何 manager、Preferences 或 `Date.now()`。

## 核心管理器

| 管理器 | 职责 |
|---|---|
| `UsageStatsManager` | 亮屏会话、跨日结算、限额三档预警、解锁统计、周趋势 |
| `ScreenStateManager` | 亮灭屏/解锁事件订阅 + `power.isActive()` 轮询兜底、解锁去重 |
| `HealthStateManager` | 5s/30s 聚合循环、跨日联动、就绪回调、健康胶囊数据 |
| `SleepManager` | 睡眠数据/目标/评分、睡前窗口统计、健康数据同步 |
| `FocusModeManager` | 番茄钟会话、积分、连击、完成/中断与提醒接力 |
| `HealthReminderManager` | 久坐/用眼/喝水 + 自定义提醒的配置与注册 |
| `OngoingReminderScheduler` | 常驻通知倒计时引擎（10s tick，文案去重） |
| `ReminderService` | 睡前/停用时间提醒的调度与重发 |
| `NotificationRepostService` | 通知被系统清理后的补发 |
| `DailyGoalManager` | 内置/自定义目标、打卡、连续天数、昨日快照 |
| `AchievementManager` | 14 枚成就的解锁判定 |
| `ThemeManager` | 深浅色、强调色（含自定义色派生）、首页布局版本 |
| `PreferenceManager` | Preferences 读写（写后 flush、异常内部兜底） |
| `DataBackupManager` | JSON 导入/导出、逐字段校验、重置 |
| `BackgroundServiceManager` | 后台长时任务（KEEP_BACKGROUND_RUNNING） |
| `PermissionService` / `HealthDataService` | 运行时权限、华为运动健康读取 |

## 数据流

```
系统亮灭屏/解锁事件 ──► ScreenStateManager ──► UsageStatsManager ──► 首页卡片 / 睡眠 / 成就
                                                      ▲
HealthStateManager 每 5s（前台）/30s（后台）聚合 ───────┘ 并驱动跨日检测

Index 1s tick ──► 读取各 manager 快照 ──► 仅在值变化时写 HomeCardData(@Observed)
Settings 保存 ──► manager 持久化 + 重新调度提醒 ──► AppStorage（强调色/称呼）──► 全站响应
```

UI 只读 `@State` / `@StorageProp` / `@ObjectLink`；不直接依赖 manager 字段做渲染（manager 是普通对象，不参与依赖追踪）。

## 定时器一览

| 位置 | 周期 | 说明 |
|---|---|---|
| `Index.refreshUI` | 1s | 首页数据刷新（后台/非首页早退） |
| `HealthStateManager.aggregateState` | 5s / 30s | 聚合、跨日、成就重算、亮屏轮询 |
| `UsageStatsManager` 刷新 | 30s | watermark 落盘、常驻使用时长通知 |
| `OngoingReminderScheduler` | 10s | 提醒到点/文案更新（内容不变时跳过发布） |
| `FocusModeManager` 计时 | 1s | 专注/休息倒计时 |
| 页面入场动画 | 一次性 | `aboutToDisappear` 统一清理 |

## 持久化

- 统一走 `PreferenceManager`（`health_prefs`），写后 `flush`；
- 读取路径对备份/旧数据做逐字段类型与范围校验（例如 `UsageStatsManager` 的记录过滤、`ReminderConfigMath` 的钳位）；
- 「重置所有数据」删除业务键后重新初始化各 manager，并清空内存态；
- 备份为单文件 JSON，`BACKUP_VERSION` 用于兼容旧版本（新增字段均为可选）。

## 测试策略

- `models/` 的纯函数（评分、统计、提醒排期、布局、颜色对比度等）由 `entry/src/test/LocalUnit.test.ets` 覆盖，可离线运行；
- 设备相关路径（通知发布、亮屏订阅、Preferences）由 `entry/src/ohosTest` 覆盖少量冒烟用例；
- 无法自动化的部分（跨午夜、系统时间、通知栏外观）在 Issue/PR 中说明人工验证步骤。

新增纯逻辑时，请同步在 `models/` 建函数 + 在 LocalUnit 增用例；这是本项目控制回归的主要手段。

## 扩展点

- **新增首页卡片**：在 `models/HealthTypes.HOME_CARD_ITEMS` 注册元数据 → `HomeCardData` 增字段 →
  `HomeCards.ets` 增组件 → `HomeCardItem` 分支 → `Index.syncCardData()` 写入。
- **新增提醒类型**：`models/ReminderItemTypes` 扩配置 → `HealthReminderManager` 注册 →
  `Settings` 增控件 → `HomeCards` 可选展示。
- **新增统计维度**：优先在 `models/UsageStatsMath` 写纯函数 + 用例，再由 manager 组装。

## 构建与 ArkTS 约束

- 项目使用 ArkTS 严格模式：禁止 `any`、无类型对象字面量、索引签名；
  `.map()` 返回对象字面量时需显式标注类型。
- 构建需要 DevEco SDK；命令行必须用 DevEco 自带 Node 调 `hvigorw.js`（详见 README）。
- 默认 unsigned HAP；签名材料不入库。
