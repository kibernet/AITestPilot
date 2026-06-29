# Model Endpoint Bridge

AI TestPilot core now includes a generic HTTP/JSON decision client for real model endpoints:

```csharp
var client = new ModelEndpointDecisionClient(
    new HttpClient(),
    new ModelEndpointDecisionClientOptions
    {
        Endpoint = new Uri("https://your-model-gateway.example/decide"),
        ApiKey = Environment.GetEnvironmentVariable("AI_TESTPILOT_MODEL_API_KEY"),
        Model = "your-model",
        RunId = "RUN-001",
        TraceDirectory = "Temp/ai-testpilot-model-trace/RUN-001",
    });
```

The client implements `IDecisionClient`, so it can be passed to `DecisionLoop` without changing snapshot capture, action execution, bug detection, or release gate code.

## Request Contract

Every request is posted as camelCase JSON:

```json
{
  "schemaVersion": "ai-testpilot.decision_request.v1",
  "model": "your-model",
  "systemPrompt": "Return exactly one JSON action...",
  "goal": "claim activity reward",
  "snapshot": {
    "scene": "Lobby",
    "stepIndex": 0,
    "ui": []
  },
  "previousSteps": [],
  "fixHints": [
    "add null guard before reward access"
  ],
  "actionSchemaVersion": "ai-testpilot.action.v1",
  "actionJsonSchema": "{ ... JSON schema string ... }",
  "allowedActions": [
    "click",
    "wait",
    "prepare_account",
    "login",
    "enter_scene",
    "close_popup",
    "claim_reward",
    "play_fishing",
    "finish"
  ]
}
```

The endpoint should return exactly one action:

```json
{
  "action": "click",
  "target": "Lobby.ActivityButton"
}
```

The parser also accepts common wrappers, including:

- `{ "decision": { "action": "finish" } }`
- `{ "aiAction": { "action": "wait", "waitMilliseconds": 250 } }`
- `{ "output_text": "{\"action\":\"finish\"}" }`
- `{ "choices": [{ "message": { "content": "{\"action\":\"finish\"}" } }] }`

## Request Formats

AI TestPilot supports two request formats:

- `NativeJson`: posts the AI TestPilot decision contract directly.
- `OpenAICompatibleChatCompletions`: wraps the same decision contract inside a chat-completions style payload with `messages` and `response_format.type=json_object`.

The chat-completions wrapper is intended for OpenAI-compatible gateways and local model gateways that expose the same high-level request shape. It still requires the model to return exactly one AI TestPilot action JSON object.

`fixHints` carries prior knowledge-graph suggestions into the decision contract. CI probes require this field to appear in both the native JSON contract and the OpenAI-compatible wrapper so the same context can be reused by model endpoints and repair-agent handoffs.

## Safety Boundary

The client validates the parsed action before it reaches the game. Unknown actions, missing click targets, and negative wait durations fail the decision call.

The current bridge is provider-neutral. Production work still needs the chosen endpoint, secret-management path, live-network smoke test, and Unity editor/runtime configuration surface.

## Unity Settings

The Unity package includes `ModelEndpointSettings`, a ScriptableObject that stores:

- endpoint URL.
- model name.
- request format.
- API key environment variable name.
- authorization scheme.
- request timeout.
- trace directory.
- live request enablement flag.
- system prompt.

Create the asset from Unity with:

`Tools/Kibernet/AI TestPilot/Create Model Endpoint Settings`

For an OpenAI-compatible gateway preset, use:

`Tools/Kibernet/AI TestPilot/Create OpenAI-Compatible Model Endpoint Settings`

The generated sample asset is saved to:

`Assets/AITestPilotGenerated/ModelEndpointSettings.asset`

The asset does not store an API key. It references an environment variable, defaulting to `AI_TESTPILOT_MODEL_API_KEY`, and live requests are disabled by default.

`ModelEndpointDecisionClient` in the Unity runtime can build the same request contract, build the OpenAI-compatible chat wrapper, parse a returned action, validate whitelist rules, and optionally run a live `UnityWebRequest` when a project explicitly enables live requests.

## Trace Evidence

When `TraceDirectory` is set, each model step writes:

- `step-0000-decision.json`
- `latest-decision.json`

Each trace contains the goal, snapshot, previous steps, system prompt, outbound request JSON, raw response JSON, parsed action, pass/fail status, and parse/validation error if one occurred.

For CI/release evidence, run:

```powershell
.\tools\Invoke-AITestPilotModelEndpointTraceProbe.ps1
```

The probe uses the real `ModelEndpointDecisionClient` against a deterministic local HTTP handler. It does not call an external model, but it proves the request contract, response parsing, action validation, and trace persistence path.

It writes these files into the evidence bundle:

- `model-endpoint-trace-manifest.json`
- `model-endpoint-request.json`
- `model-endpoint-response.json`
- `model-endpoint-decision-trace.json`

The repo-side release gate requires those files before it allows release.

## Provider Diagnostics

Provider diagnostics are an offline preflight for endpoint configuration:

```powershell
.\tools\Invoke-AITestPilotModelEndpointProviderDiagnostics.ps1
```

The script writes `model-endpoint-provider-diagnostics-manifest.json` into the evidence bundle. It records:

- provider presets for `native-json-gateway`, `openai-chat-completions`, `openai-compatible-gateway`, and `local-openai-compatible`.
- supported request formats: `NativeJson` and `OpenAICompatibleChatCompletions`.
- the selected preset, based on `AITESTPILOT_MODEL_PROVIDER` when set or the request format otherwise.
- whether endpoint, model, and API-key environment variables are configured.
- whether live smoke has enough configuration to run.

The manifest never serializes the API key value. The release gate requires this diagnostics manifest so CI can prove the endpoint setup surface is documented and machine-readable even when live network validation is intentionally skipped.

Supported `AITESTPILOT_MODEL_PROVIDER` values include:

- `native-json-gateway`
- `openai-chat-completions`
- `openai-compatible-gateway`
- `local-openai-compatible`

## Provider Retry Policy

Provider-specific retry policy is validated offline:

```powershell
.\tools\Invoke-AITestPilotModelEndpointProviderRetryPolicyProbe.ps1
```

The probe reads `model-endpoint-provider-diagnostics-manifest.json` and writes `model-endpoint-provider-retry-policy-manifest.json`. It covers `native-json-gateway`, `openai-chat-completions`, `openai-compatible-gateway`, and `local-openai-compatible` across the live failure categories used by smoke manifests: `auth`, `rate_limit`, `request_or_endpoint`, `provider_unavailable`, `timeout`, `network`, `empty_response`, `response_contract`, `configuration`, and `unknown`.

Each matrix entry records:

- retryability.
- recommended retry count.
- first backoff and maximum backoff.
- escalation owner.
- alert route.
- release-gate action.

The manifest also publishes recommended production CI arguments for required live smoke. This probe does not call a provider and does not prove credentials or model access; it proves that release artifacts contain provider-specific handling for live endpoint failures before a real endpoint is made mandatory.

## Endpoint Config Kit

Host projects can prepare the live endpoint configuration contract before credentials or provider access are available:

```powershell
.\tools\New-AITestPilotLiveModelEndpointConfigKit.ps1
```

The kit writes:

- `live-model-endpoint-config.json`
- `live-model-endpoint-config-schema.md`
- `live-model-endpoint-smoke-runbook.md`
- `README.md`
- `live-model-endpoint-config-kit-generated-manifest.json`

The default generated config is intentionally pending. It records the expected provider preset, endpoint URL, model id, request format, API-key environment variable, secret reference, timeout, trace directory, and smoke command fields, but it does not contain a secret value and does not claim that a provider has been called.

To ingest a host-project config directory:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointConfigIntake.ps1 -ConfigDir "path\to\live-model-config"
```

`-RequireCompleteConfiguration` turns missing endpoint, model, API-key reference, request format, or completion flags into a hard failure. A complete static config can be marked `READY_FOR_LIVE_SMOKE`; that only means CI has enough non-secret configuration to run the live smoke. It still records `liveSmokeExecuted=false` until `Invoke-AITestPilotLiveModelEndpointSmoke.ps1 -RequireLive` succeeds.

For release evidence, the pipeline runs:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointConfigKitProbe.ps1
```

That probe stores the pending template in release evidence, runs an isolated accepted fixture through config intake to prove the schema, and then generates a pending config outside the repository under the system temp directory to prove repo-external configs are read and blocked when incomplete. Its manifest records `releasePipelineUsesFixture=false`, `secretsSerialized=false`, `liveSmokeExecuted=false`, and `productionLiveEndpointAccessProven=false`.

## External Smoke Evidence Intake

When a host project has already run the live smoke and exported evidence, CI can ingest that directory instead of requiring this repository process to hold provider credentials:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointSmokeEvidenceIntake.ps1 -SmokeEvidenceDir "path\to\live-smoke-evidence" -RequireLiveModelEndpointSmoke -PromoteToCanonical
```

The evidence directory must contain:

- `live-model-endpoint-smoke-manifest.json`
- `live-model-endpoint-decision-trace.json`

Accepted evidence must be a real `status=PASS` live HTTP endpoint smoke using `ModelEndpointDecisionClient`, with endpoint and model configured, API key accepted or explicitly not required, action schema and allowed-action evidence present, response validation passing, a parsed action, at least one attempt, and a `LIVE-MODEL-ENDPOINT-SMOKE` trace with request and response JSON. `-PromoteToCanonical` copies the accepted manifest and trace into the canonical release-gate filenames.

The default release pipeline also runs:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointExternalSmokeIntakeProbe.ps1
```

That probe writes a deterministic SKIPPED smoke manifest outside the repository, runs intake with `-RequireLiveModelEndpointSmoke`, and expects it to fail. It proves the external handoff path is inspected and that skipped evidence cannot satisfy required live smoke.

## Failure Classification

Live smoke writes a classified `FAIL` manifest when a configured endpoint is reachable enough to execute the probe command but the request fails. The manifest includes `failureCategory`, `failureMessage`, `failureRemediation`, and `failurePolicy`.

The current categories and primary remediation paths are:

- `auth`: check the API key environment variable, authorization scheme, and model access.
- `rate_limit`: honor provider retry windows, lower CI concurrency, or use a cheaper smoke model.
- `request_or_endpoint`: verify endpoint route and request format, then inspect the persisted request trace.
- `provider_unavailable`: check upstream provider or gateway health before requiring live smoke.
- `timeout`: tune timeout seconds, model choice, or gateway latency.
- `network`: verify DNS, proxy, firewall, TLS trust, and local gateway availability.
- `empty_response`: inspect gateway/proxy logs for empty or prematurely closed responses.
- `response_contract`: fix the prompt or adapter so the provider returns exactly one whitelisted AI TestPilot action.
- `configuration`: set absolute endpoint URL, model, and request format; rerun provider diagnostics.
- `unknown`: inspect trace and provider logs, then classify the provider-specific failure.

`failurePolicy` is machine-readable and contains:

- `retryable`: whether the failure is worth retrying automatically.
- `recommendedRetryCount`: bounded retry count for transient categories.
- `backoffSeconds`: first backoff window before retry.
- `escalation`: owner path such as `secret_or_model_access_owner`, `provider_quota_owner`, `ci_network_owner`, or `model_prompt_or_gateway_adapter_owner`.
- `releaseGateAction`: current gate behavior, usually `block` or `block_if_required`.

`Invoke-AITestPilotLiveModelEndpointSmoke.ps1` executes retryable policies before returning failure. It records:

- `retryPolicyExecuted`: whether policy retry was enabled.
- `maxPolicyRetries`: wrapper cap for policy retries.
- `maxRetryBackoffSeconds`: wrapper cap for sleeps between retries.
- `attemptCount`: number of live attempts performed.
- `attempts[]`: per-attempt exit code, status, failure category, retryability, recommended retry count, escalation path, and whether another retry was scheduled.

Useful controls:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1 -MaxPolicyRetries 2 -MaxRetryBackoffSeconds 5
.\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1 -DisableFailurePolicyRetry
```

The release gate validates attempt evidence when a configured live smoke ends in `FAIL`. Complete retry evidence does not allow release by itself; it proves the failure was handled according to policy before the gate blocks.

To prove the classification path without calling a real provider:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointFailureProbe.ps1
```

The probe uses a deterministic HTTP 401 response and passes only when release evidence records `failureCategory=auth`, auth remediation hints, `retryable=false`, escalation to `secret_or_model_access_owner`, a failed decision trace, the OpenAI-compatible request format, and request-contract markers.

## Live Smoke

To run a real endpoint smoke test, configure these environment variables:

- `AITESTPILOT_LIVE_MODEL_ENDPOINT`: HTTP endpoint that accepts the AI TestPilot decision request contract.
- `AI_TESTPILOT_MODEL_API_KEY`: API key sent with the configured authorization scheme.
- `AITESTPILOT_LIVE_MODEL`: model identifier passed in the request.
- `AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT`: optional request format, either `NativeJson` or `OpenAICompatibleChatCompletions`; defaults to `NativeJson`.

Then run:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1
```

By default, the script writes `live-model-endpoint-smoke-manifest.json` with `status=SKIPPED` when those environment variables are missing. This keeps local and offline CI runs deterministic.

Production CI can require the live smoke:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1 -RequireLive
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke
```

For local OpenAI-compatible gateways that intentionally do not require authentication, run live smoke with:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1 -RequireLive -AllowMissingApiKey
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke -AllowMissingModelApiKey
```

When required, missing configuration or a failed live response blocks the release gate. When the live call passes, the evidence bundle includes:

- `live-model-endpoint-smoke-manifest.json`
- `live-model-endpoint-decision-trace.json`
