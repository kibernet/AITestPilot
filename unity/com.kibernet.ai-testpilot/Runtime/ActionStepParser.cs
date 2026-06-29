using System;

namespace Kibernet.AITestPilot.Unity
{
    public static class ActionStepParser
    {
        public static AIAction Parse(string step)
        {
            if (string.IsNullOrWhiteSpace(step))
            {
                throw new InvalidOperationException("Action step is empty.");
            }

            var separator = step.IndexOf(':');
            var action = separator < 0 ? step : step.Substring(0, separator);
            var target = separator < 0 ? string.Empty : step.Substring(separator + 1);
            var result = new AIAction { action = action, target = target };

            if (string.Equals(action, ActionWhitelist.Wait, StringComparison.OrdinalIgnoreCase))
            {
                int waitMilliseconds;
                if (int.TryParse(target, out waitMilliseconds))
                {
                    result.waitMilliseconds = waitMilliseconds;
                }
            }

            if (!ActionWhitelist.IsAllowed(result.action))
            {
                throw new InvalidOperationException("Action step is not whitelisted: " + step);
            }

            return result;
        }

        public static string Format(AIAction action)
        {
            if (action == null)
            {
                return string.Empty;
            }

            if (string.IsNullOrWhiteSpace(action.target))
            {
                return action.action;
            }

            return action.action + ":" + action.target;
        }
    }
}
