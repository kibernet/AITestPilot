using System;
using System.Collections.Generic;

namespace Kibernet.AITestPilot.Unity
{
    public static class BugDetector
    {
        public static bool HasBug(AITestSnapshot snapshot)
        {
            return TryBuildPackage(snapshot, null) != null;
        }

        public static BugPackage TryBuildPackage(AITestSnapshot snapshot, IList<string> steps)
        {
            if (snapshot == null || snapshot.logs == null)
            {
                return null;
            }

            foreach (var log in snapshot.logs)
            {
                if (IsBugLog(log))
                {
                    return new BugPackage
                    {
                        bugId = "BUG-" + Math.Abs((snapshot.scene + log.message + DateTime.UtcNow.Ticks).GetHashCode()).ToString("X8"),
                        type = Classify(log.message),
                        scene = snapshot.scene,
                        log = log.message,
                        stackTrace = log.stackTrace,
                        risk = ResolveRisk(log),
                        createdAtUtc = DateTime.UtcNow.ToString("O"),
                        steps = steps == null ? new List<string>() : new List<string>(steps)
                    };
                }
            }

            return null;
        }

        private static bool IsBugLog(LogEntrySnapshot log)
        {
            if (log == null)
            {
                return false;
            }

            if (string.Equals(log.type, "Error", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(log.type, "Exception", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(log.type, "Assert", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            return !string.IsNullOrEmpty(log.message) &&
                   (log.message.IndexOf("Exception", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    log.message.IndexOf("Error", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    log.message.IndexOf("Crash", StringComparison.OrdinalIgnoreCase) >= 0);
        }

        private static string Classify(string message)
        {
            if (!string.IsNullOrEmpty(message) &&
                message.IndexOf("NullReferenceException", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "NullReference";
            }

            if (!string.IsNullOrEmpty(message) &&
                message.IndexOf("Lua", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "LuaRuntime";
            }

            return "RuntimeError";
        }

        private static string ResolveRisk(LogEntrySnapshot log)
        {
            if (string.Equals(log.type, "Exception", StringComparison.OrdinalIgnoreCase) ||
                (!string.IsNullOrEmpty(log.message) &&
                 log.message.IndexOf("NullReferenceException", StringComparison.OrdinalIgnoreCase) >= 0))
            {
                return "HIGH";
            }

            return "MEDIUM";
        }
    }
}
