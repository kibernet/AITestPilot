using System;
using System.Collections.Generic;

namespace Kibernet.AITestPilot.Unity
{
    [Serializable]
    public sealed class BugPackage
    {
        public string bugId;
        public string type;
        public string scene;
        public string log;
        public string stackTrace;
        public string risk;
        public string module;
        public string function;
        public string createdAtUtc;
        public List<string> steps = new List<string>();
    }
}
