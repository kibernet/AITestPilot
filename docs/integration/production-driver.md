# Production Replay Driver Integration

Use this integration path when a real Unity project needs AI TestPilot to replay business actions during repair retests.

## Driver Shape

Implement a parameterless type that inherits `HookedGameActionReplayDriver`:

```csharp
using System.Collections.Generic;
using Kibernet.AITestPilot.Unity;

namespace Your.Game.Tests
{
    public sealed class ProductionReplayDriver : HookedGameActionReplayDriver
    {
        public ProductionReplayDriver()
            : base(
                "your_game.production_replay",
                new ProductionReplayHooks(),
                new GameActionReplayState(),
                BuildDescriptor())
        {
        }

        private static GameActionReplayDriverDescriptor BuildDescriptor()
        {
            return new GameActionReplayDriverDescriptor
            {
                driverId = "your_game.production_replay",
                displayName = "Your Game Production Replay Driver",
                supportedHandlerKeys = GameActionReplayDriverDescriptorFactory.StandardHandlerKeys(),
                configurationRequirements = new List<GameActionReplayConfigurationRequirement>
                {
                    new GameActionReplayConfigurationRequirement
                    {
                        key = "AITESTPILOT_QA_ACCOUNT",
                        source = "environment",
                        required = true,
                        description = "QA account alias used by prepare_account and login."
                    }
                }
            };
        }
    }
}
```

Then implement `ProductionReplayHooks` by calling the game's own login, account, scene, activity, and fishing APIs. Each hook should return `GameActionReplayHookResult.Pass(...)` only after the game is in the expected state.

## Integration Plan Checklist

Before a project has real game API hooks, create the checklist asset from Unity:

`Tools/Kibernet/AI TestPilot/Create Production Replay Integration Plan`

The asset is written to:

`Assets/AITestPilotGenerated/ProductionReplayIntegrationPlan.asset`

Batch sample-scene validation creates the same template automatically and exports two release-evidence files:

- `production-replay-integration-checklist.json`
- `production-replay-integration-checklist.md`

Those files must show `status=TEMPLATE_READY`, `realProjectBound=false`, five required hooks, zero bound hooks, and five unresolved hooks. This is deliberate: the checklist proves that the handoff surface is complete and that the repo is not claiming real production APIs are already bound.

Flip `realProjectBound=true` only after each required hook calls the real project API and verifies the resulting game state.

## Required Hooks

- `PrepareAccount`: create, reset, or select the QA account named by `context.target`.
- `Login`: login with that account and wait until the lobby or first stable scene is ready.
- `EnterScene`: navigate to the requested scene or feature.
- `ClaimReward`: claim the requested activity reward.
- `PlayFishing`: execute the requested fishing command.

## Batch Retest

Run the targeted retest with the production driver type:

```powershell
.\tools\Invoke-AITestPilotRepairRetest.ps1 -GameReplayDriverType "Your.Game.Tests.ProductionReplayDriver"
```

The retest evidence records:

- `gameReplayDriverId`: driver id passed to `HookedGameActionReplayDriver`.
- `gameReplayDriverSource`: `type:<full type name>` when `-GameReplayDriverType` is used.
- `gameReplayDriverDescriptor`: supported handler keys and configuration requirements declared by the driver.
- `replayedActions[].message`: hook diagnostics with driver, handler key, action, target, step, and message.
- `businessReplayState`: counters for account setup, login, scene entry, reward claim, and fishing.

## Capability And Configuration Declaration

Every production driver should declare:

- `supportedHandlerKeys`: the `game.*` handlers the driver can replay.
- `configurationRequirements`: required environment variables, repair-task targets, account aliases, server/shard names, or other setup inputs.
- `notes`: operator-facing setup notes that should appear in evidence.

The retest wrapper validates that the descriptor exists, matches the selected driver, supports all standard handler keys, and includes complete configuration requirement entries.

## Failure Probe

Before wiring a real project driver into CI, run the failure probe:

```powershell
.\tools\Invoke-AITestPilotReplayDriverFailureProbe.ps1
```

The probe uses `FailingGameActionReplayDriver`, expects Unity batchmode to fail at `game.claim_reward`, and writes `repair-driver-failure-manifest.json`. It passes only when the Unity log includes the failing driver id, handler key, action, target, and step.

## Release Gate

After scene validation, positive repair retest, failure probe, and replay profile import have run, execute:

```powershell
.\tools\Invoke-AITestPilotReleaseGate.ps1
```

The gate blocks release when the driver descriptor is missing, required handler keys are not declared, configuration requirements are incomplete, the negative failure probe is missing, the targeted retest failed, or any listed evidence file is absent.

To test that the gate blocks incomplete driver evidence:

```powershell
.\tools\Invoke-AITestPilotReleaseGateFailureProbe.ps1
```

To require a real production binding instead of accepting the package-release sample/unbound boundary:

```powershell
.\tools\Invoke-AITestPilotProductionReplayDriverReadiness.ps1 -RequireProductionBound
.\tools\Invoke-AITestPilotReleaseGate.ps1 -RequireProductionReplayDriverBound
```

The one-command CI wrapper exposes the same policy:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -GameReplayDriverType "Your.Game.Tests.ProductionReplayDriver" -RequireProductionReplayDriverBound
```

The default package-release pipeline also runs `Invoke-AITestPilotProductionReplayDriverBoundFailureProbe.ps1`, which proves the current sample/unbound evidence fails when `-RequireProductionBound` is enforced. Keep that failure probe in package-release CI until a real project supplies bound hooks and a non-sample `type:` driver.

## Template

The package includes a copyable template at:

`unity/com.kibernet.ai-testpilot/Samples~/ProductionReplayDriver/ProductionReplayDriverTemplate.cs`
