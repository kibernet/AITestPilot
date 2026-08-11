# AITestPilot 落地与发布验收模板

本文档提供可直接复用的上线推进与 PR 发布校验模板，目标是把项目中的门禁命令转化为可追责的团队流程。

## 适用范围

- 新项目接入 AITestPilot 时的试点推进（第一周）
- 按既有产品线持续集成后重构后的回归验收
- 发布前里程碑（里程碑冻结、候选包冻结）前质量复核

> [!TIP]
> 该模板补充 `local-workflow-cheat-sheet.md` 的命令级清单；你可按团队节奏缩放执行频率。

## 一、7 天试点推进清单

### 第 1-3 天：验证闭环打底

- [ ] 新项目代码检出后，执行：
  - `.\tools\Validate-AITestPilot.ps1`
  - `.\tools\Invoke-AITestPilotLocalPreflight.ps1`
- [ ] 约束 Unity 内置标注规范：
  - `AutomationId` 最低覆盖主入口、关键状态切换点、核心结果界面
- [ ] 形成项目级证据目录策略（如：统一归档到 `Temp\` 下并保留版本标签）
- [ ] 产物确认：
  - `Temp\quick-start\quick-start-manifest.json`
  - `Temp\developer-gate-manifest.json`

### 第 4-7 天：PR 门禁与协作规范化

- [ ] PR 模板中加入门禁结果复核项（至少包含：
  - `Run-DevGate.ps1`
  - `Run-CiGatePathRegression`
  - `Run-CiGatePathRegressionStrict` 的执行记录）
- [ ] 提交说明约束：
  - 失败步骤/跳过步骤必须写明原因
  - 失败修复必须附重现路径和证据位置
- [ ] 生产 replay driver 的最小可测实现至少覆盖：登录、场景进入、奖励/核心结果确认
- [ ] 产物确认：
  - `Temp\dev-gate-summary.json`
  - `Temp\ci-gate-summary.json`

## 二、30 天持续化验收清单

- [ ] 关键路径固定加入回归：`Run-CiGatePathRegression`（每周一次）
- [ ] 关键路径 strict 规则固定加入回归：`Run-CiGatePathRegressionStrict`（每两周一次或触达 CI 门禁变更时）
- [ ] 所有修复任务必须执行“三段式”：
  - 补丁前置校验
  - 回归重测
  - 回滚证据输出
- [ ] 里程碑前执行发布前流水线：
  - `.\tools\Invoke-AITestPilotReleasePipeline.ps1`
- [ ] 产物存档（可追溯）：
  - `artifacts\ai-testpilot-release\latest\`（发布归档）
  - `Temp\release-evidence\latest\`（版本级证据）

## 三、可直接粘贴到 PR 的最小模板

```text
## Validation run
- [ ] .\tools\Run-DevGate.ps1
- [ ] .\tools\Validate-AITestPilot.ps1
- [ ] .\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
- [ ] .\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict *(if touched path logic)*
- [ ] .\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json
- [ ] .\tools\Invoke-AITestPilotReleasePipeline.ps1 *(for release milestone only)*

Artifacts produced:
- [ ] Temp\developer-gate-manifest.json
- [ ] Temp\dev-gate-summary.json
- [ ] Temp\ci-gate-summary.json (if CI/paths are run)
- [ ] Temp\release-evidence\latest\...
- [ ] artifacts\ai-testpilot-release\latest\... (if release pipeline is run)

Skipped / partial steps:
- [ ] Please list skipped command(s) and reason(s), with owner approval.
```

## 四、验收阈值（上线标准）

上线（通过）至少满足以下条件：

- [ ] 本地门禁和至少一次 CI 路径回归通过
- [ ] 修复闭环中可追溯：问题包 -> 修复任务 -> 重测 -> 回滚证据
- [ ] 关键路径 release pipeline 产出可归档
- [ ] 证据文件可复用、可比对、可追责

## 五、与其他文档的映射

- 日常命令入口：`docs/local-workflow-cheat-sheet.md`
- PR 与工作流：`CONTRIBUTING.md`
- 生产接入点：`docs/integration/production-driver.md`
- 发布流水线：`docs/ci-release-pipeline.md`
