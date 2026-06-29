using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

namespace Kibernet.AITestPilot.Unity
{
    public static class UIExtractor
    {
        public static List<UiElementSnapshot> GetAll()
        {
            var result = new List<UiElementSnapshot>();
            var ids = Object.FindObjectsOfType<AutomationId>();

            foreach (var automationId in ids)
            {
                if (automationId == null || !automationId.includeInSnapshot)
                {
                    continue;
                }

                result.Add(new UiElementSnapshot
                {
                    automationId = automationId.id,
                    name = automationId.gameObject.name,
                    kind = ResolveKind(automationId.gameObject),
                    interactable = ResolveInteractable(automationId.gameObject),
                    active = automationId.gameObject.activeInHierarchy
                });
            }

            result.Sort((left, right) => string.CompareOrdinal(left.automationId, right.automationId));
            return result;
        }

        private static string ResolveKind(GameObject gameObject)
        {
            if (gameObject.GetComponent<Button>() != null)
            {
                return "Button";
            }

            if (gameObject.GetComponent<Toggle>() != null)
            {
                return "Toggle";
            }

            if (gameObject.GetComponent<InputField>() != null)
            {
                return "InputField";
            }

            if (gameObject.GetComponent<Canvas>() != null)
            {
                return "Canvas";
            }

            return gameObject.GetType().Name;
        }

        private static bool ResolveInteractable(GameObject gameObject)
        {
            var button = gameObject.GetComponent<Button>();
            if (button != null)
            {
                return button.interactable;
            }

            var selectable = gameObject.GetComponent<Selectable>();
            return selectable == null || selectable.interactable;
        }
    }
}
