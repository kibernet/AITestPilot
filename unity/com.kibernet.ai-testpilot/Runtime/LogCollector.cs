using System;
using System.Collections.Generic;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity
{
    public static class LogCollector
    {
        private const int MaxStoredLogs = 500;
        private static readonly List<LogEntrySnapshot> Logs = new List<LogEntrySnapshot>();
        private static bool initialized;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        public static void Init()
        {
            if (initialized)
            {
                return;
            }

            Application.logMessageReceived += OnLogMessageReceived;
            initialized = true;
        }

        public static List<LogEntrySnapshot> Get()
        {
            return new List<LogEntrySnapshot>(Logs);
        }

        public static void Clear()
        {
            Logs.Clear();
        }

        private static void OnLogMessageReceived(string condition, string stackTrace, LogType type)
        {
            Logs.Add(new LogEntrySnapshot
            {
                type = type.ToString(),
                message = condition,
                stackTrace = stackTrace,
                timestampUtc = DateTime.UtcNow.ToString("O")
            });

            if (Logs.Count > MaxStoredLogs)
            {
                Logs.RemoveRange(0, Logs.Count - MaxStoredLogs);
            }
        }
    }
}
