using System;
using System.Collections.Generic;

namespace Kibernet.AITestPilot.Unity
{
    [Serializable]
    public sealed class AITestSnapshot
    {
        public string scene;
        public int stepIndex;
        public string capturedAtUtc;
        public List<UiElementSnapshot> ui = new List<UiElementSnapshot>();
        public List<GameStateEntry> gameState = new List<GameStateEntry>();
        public List<LogEntrySnapshot> logs = new List<LogEntrySnapshot>();
    }

    [Serializable]
    public sealed class UiElementSnapshot
    {
        public string automationId;
        public string name;
        public string kind;
        public bool interactable;
        public bool active;
    }

    [Serializable]
    public sealed class GameStateEntry
    {
        public string key;
        public string value;
    }

    [Serializable]
    public sealed class LogEntrySnapshot
    {
        public string type;
        public string message;
        public string stackTrace;
        public string timestampUtc;
    }
}
