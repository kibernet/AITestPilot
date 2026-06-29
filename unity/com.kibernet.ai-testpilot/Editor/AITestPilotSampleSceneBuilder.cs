using System;
using Kibernet.AITestPilot.Unity;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class AITestPilotSampleSceneBuilder
    {
        public const string ButtonAutomationId = "Sample.Lobby.StartButton";

        [MenuItem("Tools/Kibernet/AI TestPilot/Create Basic Automation Sample Scene")]
        public static void CreateBasicAutomationSampleScene()
        {
            CreateScene(null);
        }

        public static SampleSceneHandle CreateScene(Action onButtonClicked)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

            var root = new GameObject("AI TestPilot Sample");

            var eventSystem = new GameObject("EventSystem");
            eventSystem.AddComponent<EventSystem>();
            eventSystem.AddComponent<StandaloneInputModule>();

            var canvasObject = new GameObject("Canvas");
            canvasObject.transform.SetParent(root.transform, false);
            var canvas = canvasObject.AddComponent<Canvas>();
            canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            canvasObject.AddComponent<CanvasScaler>();
            canvasObject.AddComponent<GraphicRaycaster>();

            var buttonObject = new GameObject("StartButton");
            buttonObject.transform.SetParent(canvasObject.transform, false);
            var rectTransform = buttonObject.AddComponent<RectTransform>();
            rectTransform.sizeDelta = new Vector2(240f, 64f);
            rectTransform.anchoredPosition = Vector2.zero;

            var image = buttonObject.AddComponent<Image>();
            image.color = new Color(0.16f, 0.45f, 0.78f, 1f);

            var button = buttonObject.AddComponent<Button>();
            var automationId = buttonObject.AddComponent<AutomationId>();
            automationId.id = ButtonAutomationId;

            button.onClick.AddListener(() =>
            {
                if (onButtonClicked != null)
                {
                    onButtonClicked();
                }

                Debug.Log("AI TestPilot sample button clicked");
            });

            var labelObject = new GameObject("Label");
            labelObject.transform.SetParent(buttonObject.transform, false);
            var labelRect = labelObject.AddComponent<RectTransform>();
            labelRect.anchorMin = Vector2.zero;
            labelRect.anchorMax = Vector2.one;
            labelRect.offsetMin = Vector2.zero;
            labelRect.offsetMax = Vector2.zero;

            var label = labelObject.AddComponent<Text>();
            label.text = "Start";
            label.alignment = TextAnchor.MiddleCenter;
            label.color = Color.white;
            label.font = Resources.GetBuiltinResource<Font>("Arial.ttf");
            label.raycastTarget = false;

            var runnerObject = new GameObject("AI TestPilot Runner");
            runnerObject.transform.SetParent(root.transform, false);
            var runner = runnerObject.AddComponent<DecisionLoopRunner>();
            runner.goal = "click the sample start button";
            runner.maxSteps = 3;
            runner.stopOnBug = false;

            return new SampleSceneHandle(root, button, automationId, runner);
        }
    }

    public sealed class SampleSceneHandle
    {
        public SampleSceneHandle(
            GameObject root,
            Button button,
            AutomationId buttonAutomationId,
            DecisionLoopRunner runner)
        {
            Root = root;
            Button = button;
            ButtonAutomationId = buttonAutomationId;
            Runner = runner;
        }

        public GameObject Root { get; }

        public Button Button { get; }

        public AutomationId ButtonAutomationId { get; }

        public DecisionLoopRunner Runner { get; }
    }
}
