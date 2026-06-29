using System.IO;
using System.Text;
using Kibernet.AITestPilot.Unity;
using UnityEditor;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public sealed class AITestPilotWindow : EditorWindow
    {
        private string goal = "explore";
        private int maxSteps = 20;
        private AITestSnapshot lastSnapshot;
        private BugKnowledgeGraphAsset knowledgeGraph;
        private ModelEndpointSettings modelEndpointSettings;

        [MenuItem("Tools/Kibernet/AI TestPilot")]
        public static void Open()
        {
            GetWindow<AITestPilotWindow>("AI TestPilot");
        }

        private void OnGUI()
        {
            EditorGUILayout.LabelField("AI TestPilot", EditorStyles.boldLabel);
            goal = EditorGUILayout.TextField("Goal", goal);
            maxSteps = EditorGUILayout.IntSlider("Max Steps", maxSteps, 1, 200);
            knowledgeGraph = (BugKnowledgeGraphAsset)EditorGUILayout.ObjectField(
                "Knowledge Graph",
                knowledgeGraph,
                typeof(BugKnowledgeGraphAsset),
                false);
            modelEndpointSettings = (ModelEndpointSettings)EditorGUILayout.ObjectField(
                "Model Endpoint",
                modelEndpointSettings,
                typeof(ModelEndpointSettings),
                false);

            EditorGUILayout.Space();

            if (GUILayout.Button("Capture Snapshot"))
            {
                CaptureSnapshot();
            }

            using (new EditorGUI.DisabledScope(lastSnapshot == null))
            {
                if (GUILayout.Button("Export Snapshot JSON"))
                {
                    ExportSnapshot();
                }

                if (GUILayout.Button("Write Cursor Bug Prompt"))
                {
                    WriteCursorPrompt();
                }
            }

            if (GUILayout.Button("Add DecisionLoopRunner To Scene"))
            {
                AddRunnerToScene();
            }

            EditorGUILayout.Space();
            if (GUILayout.Button("Create Model Endpoint Settings"))
            {
                CreateModelEndpointSettings();
            }

            using (new EditorGUI.DisabledScope(modelEndpointSettings == null || lastSnapshot == null))
            {
                if (GUILayout.Button("Validate Model Endpoint Contract"))
                {
                    ValidateModelEndpointContract();
                }
            }

            if (GUILayout.Button("Create Production Replay Integration Plan"))
            {
                CreateProductionReplayIntegrationPlan();
            }

            EditorGUILayout.Space();
            DrawSnapshotSummary();
        }

        private void CaptureSnapshot()
        {
            LogCollector.Init();
            lastSnapshot = SnapshotProvider.Capture(0);
            Repaint();
        }

        private void ExportSnapshot()
        {
            var root = Path.GetFullPath(Path.Combine(Application.dataPath, ".."));
            var dir = Path.Combine(root, "Temp", "AITestPilot");
            Directory.CreateDirectory(dir);

            var path = Path.Combine(dir, "last_snapshot.json");
            File.WriteAllText(path, JsonUtility.ToJson(lastSnapshot, true), Encoding.UTF8);
            Debug.Log("AI TestPilot snapshot exported: " + path);
        }

        private void WriteCursorPrompt()
        {
            var bug = BugDetector.TryBuildPackage(lastSnapshot, null);
            if (bug == null)
            {
                Debug.LogWarning("AI TestPilot did not find a bug in the current snapshot.");
                return;
            }

            var suggestedFix = knowledgeGraph == null ? null : knowledgeGraph.SuggestFix(bug);
            var path = CursorBridge.WriteBugPrompt(bug, suggestedFix);
            CursorBridge.TryOpenCursor(path);
        }

        private void AddRunnerToScene()
        {
            var go = new GameObject("AI TestPilot Runner");
            var runner = go.AddComponent<DecisionLoopRunner>();
            runner.goal = goal;
            runner.maxSteps = maxSteps;
            Selection.activeGameObject = go;
            Undo.RegisterCreatedObjectUndo(go, "Create AI TestPilot Runner");
        }

        private void CreateModelEndpointSettings()
        {
            modelEndpointSettings = ModelEndpointSettingsAssetUtility.CreateOrUpdateSampleSettings(
                ModelEndpointSettingsAssetUtility.DefaultSettingsAssetPath);
            Selection.activeObject = modelEndpointSettings;
        }

        private void ValidateModelEndpointContract()
        {
            var evidence = ModelEndpointSettingsAssetUtility.ValidateOfflineContract(
                modelEndpointSettings,
                lastSnapshot);
            if (string.Equals(evidence.status, "PASS", System.StringComparison.OrdinalIgnoreCase))
            {
                Debug.Log("PASS AI TestPilot model endpoint contract: " + evidence.settingsAssetPath);
            }
            else
            {
                Debug.LogWarning("AI TestPilot model endpoint contract failed: " + evidence.settingsAssetPath);
            }
        }

        private static void CreateProductionReplayIntegrationPlan()
        {
            var plan = ProductionReplayIntegrationPlanAssetUtility.CreateOrUpdateTemplatePlan(
                ProductionReplayIntegrationPlanAssetUtility.DefaultPlanAssetPath);
            Selection.activeObject = plan;
        }

        private void DrawSnapshotSummary()
        {
            if (lastSnapshot == null)
            {
                EditorGUILayout.HelpBox("No snapshot captured.", MessageType.Info);
                return;
            }

            EditorGUILayout.LabelField("Scene", lastSnapshot.scene);
            EditorGUILayout.LabelField("UI Elements", lastSnapshot.ui == null ? "0" : lastSnapshot.ui.Count.ToString());
            EditorGUILayout.LabelField("Logs", lastSnapshot.logs == null ? "0" : lastSnapshot.logs.Count.ToString());

            var bug = BugDetector.TryBuildPackage(lastSnapshot, null);
            EditorGUILayout.LabelField("Bug", bug == null ? "No" : bug.type + " / " + bug.risk);
        }
    }
}
