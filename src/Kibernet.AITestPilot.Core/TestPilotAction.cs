namespace Kibernet.AITestPilot.Core;

public sealed class TestPilotAction
{
    public string Action { get; init; } = ActionVerbs.Finish;

    public string? Target { get; init; }

    public int WaitMilliseconds { get; init; }

    public Dictionary<string, string> Parameters { get; init; } = new(StringComparer.OrdinalIgnoreCase);

    public bool IsFinish => string.Equals(Action, ActionVerbs.Finish, StringComparison.OrdinalIgnoreCase);

    public static TestPilotAction Click(string target)
    {
        return new TestPilotAction { Action = ActionVerbs.Click, Target = target };
    }

    public static TestPilotAction Wait(int milliseconds)
    {
        return new TestPilotAction { Action = ActionVerbs.Wait, WaitMilliseconds = milliseconds };
    }

    public static TestPilotAction Finish()
    {
        return new TestPilotAction { Action = ActionVerbs.Finish };
    }

    public void Validate()
    {
        if (!ActionVerbs.IsAllowed(Action))
        {
            throw new InvalidOperationException($"Action '{Action}' is not allowed.");
        }

        if (string.Equals(Action, ActionVerbs.Click, StringComparison.OrdinalIgnoreCase) &&
            string.IsNullOrWhiteSpace(Target))
        {
            throw new InvalidOperationException("Click actions require a target.");
        }

        if (string.Equals(Action, ActionVerbs.Wait, StringComparison.OrdinalIgnoreCase) &&
            WaitMilliseconds < 0)
        {
            throw new InvalidOperationException("Wait actions cannot use a negative duration.");
        }
    }
}
