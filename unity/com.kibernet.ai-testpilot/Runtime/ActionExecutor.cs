using System;
using System.Collections;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.UI;

namespace Kibernet.AITestPilot.Unity
{
    public static class ActionExecutor
    {
        public static Action<AIAction> PlayFishingHandler;

        public static bool Execute(AIAction action)
        {
            if (action == null || !ActionWhitelist.IsAllowed(action.action))
            {
                throw new InvalidOperationException("AI action is missing or not whitelisted.");
            }

            if (string.Equals(action.action, ActionWhitelist.Click, StringComparison.OrdinalIgnoreCase))
            {
                return Click(action.target);
            }

            if (string.Equals(action.action, ActionWhitelist.EnterScene, StringComparison.OrdinalIgnoreCase))
            {
                SceneManager.LoadScene(action.target);
                return true;
            }

            if (string.Equals(action.action, ActionWhitelist.ClosePopup, StringComparison.OrdinalIgnoreCase))
            {
                return ClosePopup(action.target);
            }

            if (string.Equals(action.action, ActionWhitelist.PlayFishing, StringComparison.OrdinalIgnoreCase))
            {
                if (PlayFishingHandler != null)
                {
                    PlayFishingHandler(action);
                }

                return true;
            }

            if (string.Equals(action.action, ActionWhitelist.Wait, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(action.action, ActionWhitelist.Finish, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            return false;
        }

        public static IEnumerator ExecuteRoutine(AIAction action)
        {
            if (action == null)
            {
                yield break;
            }

            if (string.Equals(action.action, ActionWhitelist.Wait, StringComparison.OrdinalIgnoreCase))
            {
                yield return new WaitForSeconds(Mathf.Max(0, action.waitMilliseconds) / 1000f);
                yield break;
            }

            Execute(action);
        }

        private static bool Click(string target)
        {
            var automationId = Find(target);
            if (automationId == null)
            {
                return false;
            }

            var button = automationId.GetComponent<Button>();
            if (button != null && button.interactable)
            {
                button.onClick.Invoke();
                return true;
            }

            var toggle = automationId.GetComponent<Toggle>();
            if (toggle != null && toggle.interactable)
            {
                toggle.isOn = !toggle.isOn;
                return true;
            }

            automationId.SendMessage("OnClick", SendMessageOptions.DontRequireReceiver);
            return true;
        }

        private static bool ClosePopup(string target)
        {
            var automationId = Find(target);
            if (automationId == null)
            {
                return false;
            }

            automationId.gameObject.SetActive(false);
            return true;
        }

        private static AutomationId Find(string target)
        {
            if (string.IsNullOrWhiteSpace(target))
            {
                return null;
            }

            var ids = UnityEngine.Object.FindObjectsOfType<AutomationId>();
            foreach (var automationId in ids)
            {
                if (automationId != null && string.Equals(automationId.id, target, StringComparison.Ordinal))
                {
                    return automationId;
                }
            }

            return null;
        }
    }
}
