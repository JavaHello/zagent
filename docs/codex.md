# ChatGPT / Codex subscription authentication

The `codex` provider talks to the ChatGPT backend with your subscription instead
of an API key. No Codex CLI installation is needed.

```sh
zagent login
export AI_PROVIDER=codex
zagent models
export AI_MODEL=gpt-5.4  # select a model available to your account
zagent "Inspect this project"
zagent logout
```

Open the official device authorization URL printed by `login` in a browser on
any device and enter the displayed code. Device authorization must be enabled
for the account. This is an independent implementation of the official Codex
protocol, not an OpenAI-published client.

## Models and quotas

`/status` shows the current model and the last turn's input/output tokens
(server usage or local estimates). With `AI_PROVIDER=codex`, it also fetches
ChatGPT subscription usage windows, showing used/remaining percentages and reset
countdowns. Other providers' account quotas must be checked in their billing
dashboards. This command does not make a model request; quota lookup failures do
not interrupt the conversation.

`models` prints the server's original JSON, so pick a name from it with
`AI_MODEL`.

## Endpoint and limits

ChatGPT credentials use `https://chatgpt.com/backend-api/codex/responses` and
`/models`; they are not API keys for `https://api.openai.com/v1`. The existing
`openai` provider continues to use separately billed API keys. The `codex`
provider rejects custom `AI_URL` values and does not use `AI_KEY` for
authentication.

Codex requests always stream, move system instructions into `instructions`, and
omit the unsupported `max_output_tokens` field. Available models and limits
depend on the account. Backend compatibility may change with the official
client.

## Credentials

Tokens are stored separately in `$HOME/.config/zagent/codex-auth.json` with mode
`0600`. Access tokens are checked before requests and refreshed near expiration;
rotated refresh tokens are saved. Do not share this file or run concurrent
logins/refreshes against it. Run `login` again after a refresh failure. `logout`
deletes local credentials without revoking the server grant. Existing Codex CLI
credentials are untouched.

## Optional request fields

Codex only, set in the config file or the environment (environment wins):

```ini
AI_REASONING_EFFORT=high
AI_SERVICE_TIER=fast
```

They are passed through as `"reasoning":{"effort":"high"}` and
`"service_tier":"fast"`. When unset or empty the field is omitted, and other
providers never send either. Whether a value is accepted is up to the model and
the backend.

References: [official authentication](https://developers.openai.com/codex/auth),
[official gateway routing](https://learn.chatgpt.com/docs/enterprise/connect-to-a-gateway?gateway-auth=api-key).
