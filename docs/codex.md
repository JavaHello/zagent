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

The list is gated by the client version `models` reports, and the parameter is
not optional: the backend answers only with the models a client of that version
may use. zagent reports the version its `codex_auth.client_version` was written
against, and `AI_CODEX_CLIENT_VERSION` overrides it for an account that has
moved on:

```sh
codex --version                                   # codex-cli 0.172.0
AI_CODEX_CLIENT_VERSION=$(codex --version | awk '{print $2}') zagent models
```

A version reported as too old does not fail — the list quietly shrinks, and a
model named from it is refused with `model_not_in_accessible_catalog`. The
setting affects model discovery only; the request itself carries no version.

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

## Overload, and what is retried

This backend sheds load rather than queueing it, and it says so inside an
answer it has already accepted: a `200` whose body reads `Our servers are
currently overloaded. Please try again later.`, or an SSE `error` event with
the code `server_overloaded`. The status page reports incidents, not this.

Such an answer is retried — up to five attempts in all — because it describes a
server that is busy rather than a request that is wrong. The first wait is one
second and doubles each time (1s, 2s, 4s, 8s); a `Retry-After` header is
honoured instead, capped at 30 seconds. Text that has already been printed is
never sent again: a stream that fails after the reply started ends the turn.

## Credentials

Tokens are stored separately, beside the config file, in
`$XDG_CONFIG_HOME/zagent/codex-auth.json` or `~/.config/zagent/codex-auth.json`,
with mode `0600`. Access tokens are checked before requests and refreshed near expiration;
rotated refresh tokens are saved. One exchange is made at a time: sub-agents hold
their own credentials but share the file, and a refresh token can be spent once,
so a turn that waits finds the token the other turn wrote instead of retiring it.
For the same reason the file is read again after a refusal — a token there that
the failed request did not send is a refresh someone else already made. A request
the backend refuses with 401 is sent once more with a freshly refreshed token;
when the refresh itself is refused, the turn reports that `zagent login` is what
is needed. Do not run concurrent logins against one file. `logout` deletes local
credentials without revoking the server grant. Existing Codex CLI credentials are
untouched.

## Optional request fields

Set in the config file or the environment (environment wins):

```ini
AI_REASONING_EFFORT=high
AI_SERVICE_TIER=fast
```

`AI_REASONING_EFFORT` is a standard Responses field, so every provider sends it
as the outer-level `"reasoning":{"effort":"high"}`. `AI_SERVICE_TIER` selects
this backend's fast mode and is the Codex-only one, sent as
`"service_tier":"fast"`. `AI_THINKING` is DeepSeek's member: this backend does
not define it and sends nothing unless the setting names it. When unset or empty
the field is omitted. Whether a value is accepted is up to the model and the
backend.

References: [official authentication](https://developers.openai.com/codex/auth),
[official gateway routing](https://learn.chatgpt.com/docs/enterprise/connect-to-a-gateway?gateway-auth=api-key).
