using System;
using System.Collections.Generic;

namespace Kibernet.AITestPilot.Unity
{
    public static class GameStateProvider
    {
        public static Func<IEnumerable<GameStateEntry>> CustomProvider;

        public static List<GameStateEntry> Get()
        {
            var state = new List<GameStateEntry>();
            if (CustomProvider == null)
            {
                return state;
            }

            foreach (var entry in CustomProvider())
            {
                if (entry != null && !string.IsNullOrWhiteSpace(entry.key))
                {
                    state.Add(entry);
                }
            }

            return state;
        }
    }
}
