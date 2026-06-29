# 🚀 Kibernet AI TestPilot（Unity AI游戏测试+修复+知识图谱系统）

---

# 🧠 1. 项目目标

构建一个 Unity 游戏 AI 自动化质量系统：

✔ 自动玩游戏  
✔ 自动点击UI  
✔ 自动探索功能  
✔ 自动发现Bug  
✔ 自动分析Lua逻辑  
✔ 自动修复代码（Cursor）  
✔ 自动修Prefab  
✔ 自动复测  
✔ 自动CI控制发版  
✔ 自动云/本地集群执行  
✔ 自动构建Bug知识图谱  
✔ 自动风险预测  

---

# 🧱 2. 系统架构

AI TestPilot
    ↓
Unity SDK（Snapshot + UI + State + Log）
    ↓
AI Decision Engine
    ↓
Action Executor
    ↓
Bug Detector
    ↓
Fix System（Cursor）
    ↓
ReTest System
    ↓
Bug Knowledge Graph
    ↓
CI/CD Gate

---

# 📦 3. Unity SDK

## AutomationId.cs
public class AutomationId : MonoBehaviour
{
    public string id;
}

---

## SnapshotProvider.cs
public class SnapshotProvider
{
    public static Snapshot Capture()
    {
        return new Snapshot
        {
            scene = SceneManager.GetActiveScene().name,
            ui = UIExtractor.GetAll(),
            gameState = GameStateProvider.Get(),
            logs = LogCollector.Get()
        };
    }
}

---

## UIExtractor.cs
public static class UIExtractor
{
    public static List<string> GetAll()
    {
        return GameObject.FindObjectsOfType<AutomationId>()
            .Select(x => x.id)
            .ToList();
    }
}

---

## GameStateProvider.cs
public static class GameStateProvider
{
    public static GameState Get()
    {
        return new GameState
        {
            coin = PlayerData.Coin,
            diamond = PlayerData.Diamond,
            scene = SceneManager.GetActiveScene().name
        };
    }
}

---

## LogCollector.cs
public static class LogCollector
{
    static List<string> logs = new();

    public static void Init()
    {
        Application.logMessageReceived += (c, s, t) =>
        {
            logs.Add(c);
        };
    }

    public static List<string> Get() => logs;
}

---

# 🤖 4. AI Agent

## DecisionLoop.cs
public class DecisionLoop
{
    public async Task Run(string goal)
    {
        while (true)
        {
            var snapshot = SnapshotProvider.Capture();

            var action = await AIClient.Decide(goal, snapshot);

            ActionExecutor.Execute(action);

            if (action.action == "finish")
                break;
        }
    }
}

---

## AI Action格式
{
  "action": "click",
  "target": "Lobby.ActivityButton"
}

---

## Action白名单
click
wait
enter_scene
close_popup
play_fishing
finish

---

# 🐛 5. Bug系统

## BugDetector.cs
public class BugDetector
{
    public static bool HasBug(List<string> logs)
    {
        return logs.Any(l =>
            l.Contains("Exception") ||
            l.Contains("Error"));
    }
}

---

## BugPackage
{
  "scene": "Activity",
  "log": "NullReferenceException",
  "steps": ["enter", "click"]
}

---

# 🔧 6. Fix System（Cursor修复）

## CursorBridge.cs
public class CursorBridge
{
    public static void Fix(BugPackage bug)
    {
        File.WriteAllText("bug_fix.md", BuildPrompt(bug));
        Process.Start("cursor", "bug_fix.md");
    }
}

---

## ReTestLoop.cs
public class ReTestLoop
{
    public static void Run()
    {
        AIController.Run("retest_last_bug");
    }
}

---

# 🧠 7. Bug Knowledge Graph（核心进化系统）

## Bug节点结构
{
  "bug_id": "B001",
  "type": "NullReference",
  "function": "claimReward",
  "module": "ActivitySystem",
  "fix": "add nil check",
  "risk": "HIGH"
}

---

## 功能
✔ 记录所有Bug  
✔ 记录函数级位置  
✔ 记录修复方式  
✔ 记录模块风险  
✔ 复用修复方案  

---

# 📊 8. CI/CD系统

## ReleaseGate.cs
public class ReleaseGate
{
    public static bool AllowRelease()
    {
        if (!BuildPipeline.Build()) return false;
        if (!TestPipeline.Run()) return false;
        if (!VisionCheck.Run()) return false;
        return true;
    }
}

---

# ☁️ 9. 集群系统（本地/云）

✔ 多Node执行  
✔ 并行测试  
✔ 任务分发  
✔ 结果汇总  

---

# 🔁 10. 完整运行流程

1. Unity启动  
2. AI开始测试  
3. 自动点击UI  
4. 自动跑游戏流程  
5. 自动发现Bug  
6. 解析Lua逻辑  
7. 写入Bug图谱  
8. Cursor修复  
9. Unity重跑  
10. AI复测  
11. CI判断是否发版  

---

# 🧠 11. 系统最终能力

✔ AI自动玩Unity游戏  
✔ AI自动找Bug  
✔ AI自动修Lua逻辑  
✔ AI自动修Prefab  
✔ AI自动复测  
✔ AI自动CI控制发版  
✔ AI自动云/本地集群  
✔ AI自动构建Bug知识图谱  
✔ AI自动风险预测  
✔ AI自动复用修复方案  

---

# 🚀 12. 系统本质

👉 一个“Unity游戏AI质量操作系统（QA OS）”

---

# 🧭 13. 最终总结

AI不只是测试工具，而是：

👉 会记忆Bug  
👉 会学习修复  
👉 会自动进化  
👉 会持续优化游戏质量的系统  