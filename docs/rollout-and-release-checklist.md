# AITestPilot 落地与发布执行清单

面向宿主项目的落地与发布验收清单。目标是把 AI TestPilot 从“可用”推进到“可交付”。

## 适用场景

- 新接入项目的首轮试运行
- PR 与里程碑发布前的统一门禁
- 需要固定合规证据链的团队交付流程

## 第 1-3 天：接入与基础验证

- [ ] 本地执行核心门禁之一
  - `.\tools\Validate-AITestPilot.ps1`
  - 或 `.\tools\Invoke-AITestPilotLocalPreflight.ps1`
- [ ] 确认输出路径与产物归档策略
  - 约定 `Temp\` 目录下的标准产物落盘约定（可写入项目文档）
- [ ] 完成 Unity 接入基础线
  - 补齐关键 `AutomationId`
  - 确认决策与日志可复现

推荐产物（基础）：

- `Temp\quick-start\quick-start-manifest.json`
- `Temp\developer-gate-manifest.json` 或 `Temp\dev-gate-summary.json`（按本地策略）

## 第 4-7 天：PR 与流程对齐

- [ ] 使用统一 PR 产物提交
  - `.\tools\Run-DevGate.ps1`
  - `.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression`
  - `.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict`（如有路径约束变更）
  - `.\tools\Validate-AITestPilot.ps1 -RunReleaseDocsFreshnessRegression`（里程碑/发布准备期建议）
- [ ] 记录失败/跳过说明
  - 在 PR 描述中列出跳过原因、影响范围、责任人
- [ ] 对齐核心业务交互
  - 完成至少一个业务流程 replay 验证（登录、场景进入、结算/领奖）
- [ ] 输出 PR 证据链
  - `Temp\developer-gate-manifest.json`
  - `Temp\dev-gate-summary.json`

## 第 8-30 天：稳定化与发布能力化

- [ ] 持续回归路径稳健性
  - 周期执行 `Run-CiGatePathRegression`
  - 周期执行 `Run-CiGatePathRegressionStrict`
- [ ] 风险矩阵建立
  - 记录失败类型、修复时长、复发率、覆盖缺口
- [ ] 发布流水线联动
  - `.\tools\Invoke-AITestPilotReleasePipeline.ps1`
  - `.\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipDocsFreshnessRegression`（如无需边界回归）
- [ ] 产物归档
  - `Temp\release-evidence\latest\`
  - `artifacts\ai-testpilot-release\latest\`

### 落地验收清单（建议）

- [ ] `Temp\developer-gate-manifest.json`
- [ ] `Temp\dev-gate-summary.json`
- [ ] `Temp\ci-gate-summary.json`
- [ ] `.\tools\Validate-AITestPilot.ps1 -RunReleaseDocsFreshnessRegression`（如启用）
- [ ] `Temp\release-evidence\latest\`
- [ ] `artifacts\ai-testpilot-release\latest\`

### 推荐 PR 模板片段

```text
## Validation run
- [ ] .\tools\Run-DevGate.ps1
- [ ] .\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
- [ ] .\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict *(if touched path logic)*
- [ ] .\tools\Validate-AITestPilot.ps1 -RunReleaseDocsFreshnessRegression *(for release milestone or docs freshness changes)*
- [ ] .\tools\Invoke-AITestPilotReleasePipeline.ps1 *(for release milestone only)*
- [ ] .\tools\Invoke-AITestPilotReleasePreflight.ps1 *(for release milestone local preflight)*

Artifacts produced:
- [ ] Temp\developer-gate-manifest.json
- [ ] Temp\dev-gate-summary.json
- [ ] Temp\ci-gate-summary.json
- [ ] Temp\release-evidence\latest\...
- [ ] artifacts\ai-testpilot-release\latest\...

Skipped / partial steps:
- [ ] Please list skipped command(s) and reason(s), with owner and owner approval.
```

## 发布后复盘动作

- [ ] 确认发布前门禁是否完整（DevGate、PathRegression、Release Pipeline）
- [ ] 确认回归结果是否覆盖关键动作路径
- [ ] 确认回归失败是否有治理闭环（修复任务、复测、回滚）

### 关联文档

- `docs/local-workflow-cheat-sheet.md`
- `docs/release-gate-review-checklist.md`
- `CONTRIBUTING.md`
- `docs/ci-release-pipeline.md`
- `docs/integration/production-driver.md`


