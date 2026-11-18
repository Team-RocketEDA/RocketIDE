# Model providers

RocketIDE does not ship its own LLM client. The pinned OpenCode runtime (1.19.5) opens the model connection,
streams the reply and runs tool calls; RocketIDE owns the provider choice, credentials, agent roles and
activity log. That means:

- a provider OpenCode already knows can be selected without changing source code;
- a custom **OpenAI-compatible** endpoint can be added with a base URL and key;
- a vendor with a proprietary protocol needs an OpenCode provider adapter, not just a base URL. A base URL
  alone cannot make an arbitrary API speak the OpenAI schema.

Meta Muse Spark 1.3 remains the default, so an existing installation keeps working.

## Where the setting lives

One canonical configuration is shared by the launcher, Rocket Fuel and the app:

```text
${XDG_CONFIG_HOME:-~/.config}/rocketide/model.json      (override: ROCKET_MODEL_CONFIG)
```

It is written by the app's **Settings → Model provider** panel and read by
`rocket_fuel/scripts/model_config.py`. The conceptual settings are:

```json
{"provider_id": "openai", "model_id": "gpt-5.1", "provider_type": "native", "base_url": null}
```

```json
{"provider_id": "custom", "model_id": "your-model", "provider_type": "openai-compatible",
 "base_url": "https://your-api.example.com/v1"}
```

Precedence, highest first:

1. explicitly exported environment variables (including the ones the app passes to the agent);
2. the saved `model.json`;
3. `.env`;
4. the Meta defaults.

`run.sh` and `rocket_fuel/scripts/dev.sh` deliberately ignore model variables that came only from `.env` when
a saved configuration exists, so switching provider in the app takes effect without editing `.env`. Values
exported before the script started (Docker `-e`, a shell export, the app) still win.

The generated project file, `.opencode/opencode.json`, uses the pinned runtime's schema: **singular
`provider`**, an `enabled_providers` list, `model`, `small_model` and each agent's `model`. The newer
`providers` (plural) key is ignored by 1.19.5 and must not be used.

## Native providers

Use OpenCode's own provider integration and its normal credential variable:

```bash
ROCKET_MODEL=openai/gpt-5.1
OPENAI_API_KEY=...
```

```bash
ROCKET_MODEL=anthropic/claude-sonnet-4-5
ANTHROPIC_API_KEY=...
```

Known provider IDs in 1.19.5 include `openai`, `anthropic`, `google`, `google-vertex`, `deepseek`,
`mistral`, `groq`, `openrouter`, `together`, `fireworks`, `xai`, `amazon-bedrock`, `azure`, `ollama`,
`lmstudio`, `github-copilot` and `opencode`. This list is a convenience, not an allowlist: another ID that
OpenCode knows also works. `ollama` and `lmstudio` need no key.

For native providers RocketIDE writes only the manually chosen model ID into the provider block; OpenCode
supplies the endpoint, protocol, capabilities and the rest of the catalog.

If OpenCode already has credentials for a provider (its `providers login` flow), it can use those. A key
entered in RocketIDE is injected into the OpenCode process environment for the session; it is never written
to a project file.

## Custom OpenAI-compatible endpoints

Select **OpenAI-compatible endpoint**, enter a provider ID, a model ID, the base URL and a key. RocketIDE
generates:

```json
{
  "provider": {
    "custom": {
      "name": "Custom",
      "npm": "@ai-sdk/openai-compatible",
      "options": {"baseURL": "https://your-api.example.com/v1", "apiKey": "{env:ROCKET_KEY_CUSTOM}"},
      "models": {"your-model": {"name": "your-model"}}
    }
  },
  "model": "custom/your-model",
  "small_model": "custom/your-model",
  "enabled_providers": ["custom"]
}
```

The key is injected under a provider-specific environment name at launch (`ROCKET_KEY_<ID>`; Meta keeps
`MODEL_API_KEY`), so two endpoints or a role on another provider never share one. The `{env:...}` value is
only a placeholder and never a key. Typical
compatible servers include vLLM, LM Studio, Ollama's OpenAI endpoint, LiteLLM, Together, Fireworks, Groq,
OpenRouter and a self-hosted gateway. Check the endpoint's own documentation for its base path: usually
`https://host/v1`, with the model ID exactly as the server reports it.

A custom endpoint is tested with a real minimal `POST {base_url}/chat/completions` request (`pong`). RocketIDE
does not assume `/v1/models` exists and does not count a merely reachable endpoint as success.

## Agent roles

| Role | Environment variable | Default |
| --- | --- | --- |
| Design agent (approval and auto profiles) | `ROCKET_MODEL` | `meta/muse-spark-1.3` |
| Small/helper model (titles, summaries) | `ROCKET_SMALL_MODEL` | main model |
| Tutor / Learn mode | `ROCKET_TUTOR_MODEL` | main model |
| Reviewer / Second opinion | `ROCKET_REVIEWER_MODEL` | `meta/muse-wonder-1.0` while the main model is Meta; otherwise the main model |

Role overrides may be a full `provider/model` reference or just a model ID for the main provider. The app's
Settings panel exposes the same three optional fields; leave them empty to inherit.

## Credentials

Keys live only on the server, outside every project:

```text
${XDG_CONFIG_HOME:-~/.config}/rocketide/credentials     (override: ROCKET_CREDENTIALS_FILE)
```

- Written mode `0600` in a `0700` folder, replaced atomically.
- Kept per provider: `{"version":1,"keys":{"meta":"...","openai":"...","custom":"..."}}`. Each provider's key
  is injected only under that provider's environment name(s), including for role models on another provider.
- The original `MODEL_API_KEY=...` file is still read as the Meta key, so existing installations need no
  migration.
- The browser can save, replace or remove a key, but every read returns only
  `{configured, source, provider}`. Keys never appear in a response, a log, a prompt or generated OpenCode
  JSON.
- `ROCKET_CREDENTIALS_FILE`, `MODEL_API_KEY`, and the provider's usual environment variable are still honoured
  for containers and CI.

Removing a key for an inactive provider leaves the other providers' keys intact.

## Capabilities and limitations

Text, streaming and tool calling are the supported baseline for every configured provider, because OpenCode
handles them. Other capabilities depend on the model and the adapter:

- **Images and PDFs** work when the model declares image/PDF modalities and the provider accepts them. If it
  does not, the assistant reports the provider's error instead of silently dropping the attachment.
- **Reasoning controls** are provider-specific. RocketIDE does not send a Meta reasoning option to another
  provider's reviewer.
- **Structured output** is not required by the agent loop and is not assumed.
- **Find in layout / SAM 3.1** is an optional Meta-only capability. It keeps using the Meta credential even
  when the design agent runs on another provider, so switching the agent never breaks it.
- A proprietary protocol (for example a vendor that is neither OpenAI-compatible nor already known to
  OpenCode) needs a provider adapter or a compatible gateway. A base URL by itself is not enough.

## Activity log

Completed model turns are written by the Rocket Fuel plugin from OpenCode's own event stream to
`logs/model-calls.jsonl` (or `ROCKET_MODEL_CALL_LOG`):

```json
{"event":"call","provider":"openai","model":"gpt-5.1","status":200,
 "duration_ms":1250,"input_tokens":1200,"output_tokens":300,"at":"..."}
```

The app reads the same file and shows provider, model, status, tokens and duration. No prompt, message body,
authorization header or key is recorded.

The optional relay (`rocket_fuel/scripts/model-relay.py`) is only for OpenAI-compatible endpoints. It is a
transparent, chunked reverse proxy: it streams the reply through without buffering and preserves status and
body. It is never inserted in front of a native provider's protocol; those calls are recorded by the plugin
instead. `meta-relay.py` remains as a compatibility wrapper.

## Adding another provider

1. If OpenCode 1.19.5 already has the provider, use its ID and a model ID. Nothing else is needed.
2. If the vendor is OpenAI-compatible, use the custom-endpoint path above.
3. If the vendor speaks another protocol, add an adapter to the pinned OpenCode runtime rather than
   hardcoding a vendor client in RocketIDE. Expose it under a provider ID and model ID; RocketIDE's
   configuration, credentials, role handling and activity log already work with any `provider/model`.
