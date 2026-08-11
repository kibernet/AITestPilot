# Release Gate Review Checklist (发布门禁复核清单)

用于版本冻结前和发布候选前的最终复核。目标是让每次发布都有同一套“可执行、可追责、可归档”的检查动作。

## 1) 门禁执行（必跑）

- [ ] `.\tools\Run-DevGate.ps1`
- [ ] `.\tools\Validate-AITestPilot.ps1`
- [ ] `.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression`
- [ ] `.\tools\Invoke-AITestPilotReleasePipeline.ps1`（如执行发布前流水线）

可选（按变更范围）：

- [ ] `.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict`
- [ ] `.\tools\Invoke-AITestPilotLocalPreflight.ps1`
- [ ] `.\tools\Invoke-AITestPilotCiGate.ps1 -SummaryPath Temp\ci-gate-summary.json`
- [ ] `.\tools\Test-AITestPilotCiGatePathResolution.ps1 -StrictOutputPathAlias`

## 2) 关键产物核验（必核）

- [ ] `Temp\developer-gate-manifest.json`
- [ ] `Temp\quick-start\quick-start-manifest.json`（如执行 quick-start）
- [ ] `Temp\repair-loop\repair-loop-manifest.json`（如执行修复回归链）
- [ ] `Temp\dev-gate-summary.json`
- [ ] `Temp\ci-gate-summary.json`（如执行 CI 门禁）
- [ ] `Temp\release-evidence\latest\`（发布证据集合）
- [ ] `artifacts\ai-testpilot-release\latest\`（发布归档，含 release manifest）

## 3) 业务与风险复核（必核）

- [ ] PR 内是否明确列出跳过项与原因（如有）
- [ ] 是否存在脚本级别未复现风险：路径、参数、空格路径、alias 冲突说明
- [ ] 是否对生产链路缺口提前声明（示例：未接入真实模型端点、未接入真实 replay driver、未接入生产 Lua 证据）
- [ ] 关键问题是否已形成“问题包 + 修复任务 + 重测结果 + 回滚依据”的闭环

## 4) 可复制输出（建议附到 Release Note 或发布工单）

可贴入发布工单的最小信息块：

```text
## Release Gate
- [ ] Run-DevGate passed
- [ ] Validate-AITestPilot passed
- [ ] Run-CiGatePathRegression passed
- [ ] Release pipeline passed (if run)

## Evidence index
- Developer gate: Temp\developer-gate-manifest.json
- Dev gate summary: Temp\dev-gate-summary.json
- CI gate summary: Temp\ci-gate-summary.json
- Release evidence: Temp\release-evidence\latest\
- Release artifacts: artifacts\ai-testpilot-release\latest\

## Risks and mitigations
- xxx
```

## 5) 与现有文档映射

- 日常工作流程：`docs/local-workflow-cheat-sheet.md`
- 上线推进模板：`docs/rollout-and-release-checklist.md`
- PR 提交指引：`CONTRIBUTING.md`
- 发布流水线：`docs/ci-release-pipeline.md`
