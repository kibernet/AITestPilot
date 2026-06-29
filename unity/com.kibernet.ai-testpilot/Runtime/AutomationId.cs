using UnityEngine;

namespace Kibernet.AITestPilot.Unity
{
    [DisallowMultipleComponent]
    public sealed class AutomationId : MonoBehaviour
    {
        public string id;
        public bool includeInSnapshot = true;

        private void Reset()
        {
            if (string.IsNullOrWhiteSpace(id))
            {
                id = BuildDefaultId(transform);
            }
        }

        public static string BuildDefaultId(Transform target)
        {
            if (target == null)
            {
                return string.Empty;
            }

            var names = new System.Collections.Generic.Stack<string>();
            var current = target;
            while (current != null)
            {
                names.Push(current.name);
                current = current.parent;
            }

            return string.Join(".", names.ToArray());
        }
    }
}
