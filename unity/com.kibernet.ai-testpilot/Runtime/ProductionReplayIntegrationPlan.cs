using System;
using System.Collections.Generic;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity
{
    [CreateAssetMenu(
        fileName = "AI TestPilot Production Replay Integration Plan",
        menuName = "Kibernet/AI TestPilot/Production Replay Integration Plan")]
    public sealed class ProductionReplayIntegrationPlan : ScriptableObject
    {
        public string schemaVersion = "ai-testpilot.production_replay_integration.v1";
        public string driverTypeName = "Your.Game.Tests.ProductionReplayDriver";
        public string driverId = "your_game.production_replay";
        public bool realProjectBound;
        public string qaAccountEnvironmentVariable = "AITESTPILOT_QA_ACCOUNT";
        public string serverEnvironmentVariable = "AITESTPILOT_SERVER";
        public List<ProductionReplayHookBinding> hookBindings = new List<ProductionReplayHookBinding>();
        public List<string> notes = new List<string>();
    }

    [Serializable]
    public sealed class ProductionReplayHookBinding
    {
        public string action;
        public string handlerKey;
        public string exampleTarget;
        public string gameApiOwner;
        public string gameApiSurface;
        public string verificationSignal;
        public bool required = true;
        public bool boundToRealGameApi;
        public string notes;
    }
}
