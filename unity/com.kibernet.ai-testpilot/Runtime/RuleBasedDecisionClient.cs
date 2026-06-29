using System;

namespace Kibernet.AITestPilot.Unity
{
    public static class RuleBasedDecisionClient
    {
        public static AIAction Decide(string goal, AITestSnapshot snapshot)
        {
            if (snapshot == null || BugDetector.HasBug(snapshot))
            {
                return AIAction.Finish();
            }

            if (snapshot.ui == null || snapshot.ui.Count == 0)
            {
                return AIAction.Finish();
            }

            for (var i = 0; i < snapshot.ui.Count; i++)
            {
                var element = snapshot.ui[i];
                if (element != null &&
                    element.active &&
                    element.interactable &&
                    string.Equals(element.kind, "Button", StringComparison.OrdinalIgnoreCase))
                {
                    return AIAction.Click(element.automationId);
                }
            }

            return AIAction.Finish();
        }
    }
}
