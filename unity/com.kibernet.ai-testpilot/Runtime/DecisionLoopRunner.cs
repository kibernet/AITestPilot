using System.Collections;
using System;
using System.Collections.Generic;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity
{
    public sealed class DecisionLoopRunner : MonoBehaviour
    {
        public string goal = "explore";
        public int maxSteps = 20;
        public bool stopOnBug = true;
        public bool runOnStart;

        private readonly List<string> steps = new List<string>();
        private Coroutine activeRun;

        public IReadOnlyList<string> Steps
        {
            get { return steps; }
        }

        private void Start()
        {
            if (runOnStart)
            {
                Run();
            }
        }

        public void Run()
        {
            if (activeRun != null)
            {
                StopCoroutine(activeRun);
            }

            activeRun = StartCoroutine(RunRoutine());
        }

        public DecisionLoopRunnerResult RunImmediate()
        {
            steps.Clear();

            var result = new DecisionLoopRunnerResult
            {
                goal = goal,
                maxSteps = maxSteps,
                exitReason = "max_steps",
                steps = new List<string>()
            };

            for (var index = 0; index < maxSteps; index++)
            {
                var snapshot = SnapshotProvider.Capture(index);
                var bug = BugDetector.TryBuildPackage(snapshot, steps);
                if (bug != null && stopOnBug)
                {
                    result.exitReason = "bug_detected";
                    result.bugDetected = true;
                    result.bugId = bug.bugId;
                    break;
                }

                var action = RuleBasedDecisionClient.Decide(goal, snapshot);
                if (action == null || string.Equals(action.action, ActionWhitelist.Finish, StringComparison.OrdinalIgnoreCase))
                {
                    result.exitReason = "finish";
                    break;
                }

                var executed = ActionExecutor.Execute(action);
                if (!executed)
                {
                    result.exitReason = "action_failed";
                    result.failedAction = Format(action);
                    break;
                }

                var step = Format(action);
                steps.Add(step);
                result.steps.Add(step);
                result.actionCount++;
            }

            result.stepCount = result.steps.Count;
            return result;
        }

        private IEnumerator RunRoutine()
        {
            steps.Clear();

            for (var index = 0; index < maxSteps; index++)
            {
                var snapshot = SnapshotProvider.Capture(index);
                var bug = BugDetector.TryBuildPackage(snapshot, steps);
                if (bug != null && stopOnBug)
                {
                    yield break;
                }

                var action = RuleBasedDecisionClient.Decide(goal, snapshot);
                if (action == null || string.Equals(action.action, ActionWhitelist.Finish, System.StringComparison.OrdinalIgnoreCase))
                {
                    yield break;
                }

                yield return ActionExecutor.ExecuteRoutine(action);
                steps.Add(Format(action));
            }
        }

        private static string Format(AIAction action)
        {
            return string.IsNullOrWhiteSpace(action.target)
                ? action.action
                : action.action + ":" + action.target;
        }
    }

    [Serializable]
    public sealed class DecisionLoopRunnerResult
    {
        public string goal;
        public int maxSteps;
        public int stepCount;
        public int actionCount;
        public string exitReason;
        public bool bugDetected;
        public string bugId;
        public string failedAction;
        public List<string> steps;
    }
}
