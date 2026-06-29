using System;
using UnityEngine.SceneManagement;

namespace Kibernet.AITestPilot.Unity
{
    public static class SnapshotProvider
    {
        public static AITestSnapshot Capture(int stepIndex = 0)
        {
            LogCollector.Init();

            return new AITestSnapshot
            {
                scene = SceneManager.GetActiveScene().name,
                stepIndex = stepIndex,
                capturedAtUtc = DateTime.UtcNow.ToString("O"),
                ui = UIExtractor.GetAll(),
                gameState = GameStateProvider.Get(),
                logs = LogCollector.Get()
            };
        }
    }
}
