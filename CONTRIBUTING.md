# 贡献指南

感谢你愿意改进萤光守护。提交 Issue / PR 前，请先阅读本指南与 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 开发环境

- DevEco Studio 6.x（含 HarmonyOS SDK）
- Node.js 随 DevEco 提供（`<DevEco>/tools/node`），无需单独安装
- 首次克隆后执行 `ohpm install --all`

完整构建/测试命令见 [README.md](README.md) 与 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 分支与提交

- 从 `main` 切出功能分支：`feat/xxx`、`fix/xxx`、`docs/xxx`
- 提交信息建议使用 Conventional Commits：
  - `feat: 首页卡片支持一键恢复默认布局`
  - `fix: 修正免打扰卡在时段外显示“未开启”`
  - `test: 补充 weekdays 非法值归一化用例`
  - `docs: 补充构建说明`
- 一个 PR 尽量只做一件事；避免“顺手重构”导致 diff 难以审查。

## 代码规范

1. **纯逻辑放 `models/`**：不读单例、不读 Preferences、不调 `Date.now()`（时间戳显式传参），
   这样可以直接被 LocalUnit 覆盖。
2. **ArkTS 严格模式**：避免 `any`、避免无类型对象字面量、避免索引签名；
   类型不明确时先定义 `interface`。
3. **状态与渲染**：`@Builder` 内直接读 `@State`，不要把状态值作为 Builder 参数传下去；
   `ForEach` 的 key 必须包含所有会变化的显示值。
4. **用户可见文案**：改动后请自查是否与实现一致；涉及统计口径时优先在测试里锁边界。
5. **日志**：统一 `hilog`（widget 文件受 FormAbility 限制可用 `console`）。
6. **不要提交**：
   - 个人路径、用户名、设备标识、真实用户数据；
   - 证书/密钥/签名材料（`.p12`、`.p7b`、`.jks`、`.keystore`）；
   - 构建产物（`build/`、`.hap`）与依赖目录（`oh_modules/`）。

## 测试要求

- 纯函数改动：补 `entry/src/test/LocalUnit.test.ets` 用例，并保证 `225+` 全绿；
- 涉及通知、亮屏事件、页面交互的改动：说明无法离线验证的原因，并附模拟器/真机验证步骤；
- 新增边界条件时，优先写“最小可复现”的断言（如 `computeStreakDays` 恰好等于限额）。

## PR 检查清单

- [ ] 已本地构建：`assembleHap`（debug）通过
- [ ] 已跑 LocalUnit：`test` 全绿，并附 `test_result.txt` 末行
- [ ] 新增/修改的逻辑有对应用例（或说明为何无法测）
- [ ] 没有提交个人路径、密钥、构建产物
- [ ] 用户可见文案与实现一致
- [ ] 如涉及权限或隐私行为变化，已同步更新 README / 应用内隐私政策

## Issue 指引

- Bug 请附：HarmonyOS 版本、设备/模拟器型号、复现步骤、期望/实际、相关 hilog；
- 功能建议请说明使用场景与现有替代方案；
- 安全问题请勿公开 Issue，见 [SECURITY.md](SECURITY.md)。
