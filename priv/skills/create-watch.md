Use when the user asks you to check something and notify them when it happens —
"avise quando o deploy concluir", "me avisa quando o site x voltar", "quando o PR
for aprovado, me chama".

This is a **watch**: a one-shot background check that messages the user once when a
condition is met, then stops. Create it with the `watch` tool (`action: "create"`).
It's durable (survives a restart and this chat closing) and replies on this same
channel.

## Pick the cheapest trigger that works

The trigger is re-checked on a timer, so make it cheap. **Always prefer a `probe`
(a shell command) over an `agent` check when the condition is scriptable** — a probe
costs no tokens per check; an agent check spends an LLM call every time.

- **Scriptable → `probe`.** Anything you can verify with a command:
  - site/endpoint up: `probe_command: "curl -sf https://x.com"` (success = exit 0).
  - a log line appeared: `probe_command: "grep -q 'Deploy complete' /var/log/app.log"`.
  - a health endpoint reports ready: `probe_command: "curl -sf https://app/health"` or
    set `probe_contains: "\"status\":\"ok\""` to match the body.
- **Needs judgement → `agent`.** Only when no command can decide it: e.g. "avise se o
  tom do cliente ficar negativo nas mensagens" → `check_prompt` with a yes/no question.
  Set a longer `interval_s` (≥ 300) to keep the cost down.

## Choose what to send (on-fire)

- Simple notice → `notify: "template"` with `message` (or omit `message` for a default).
  Costs nothing.
- Needs analysis/composition → `notify: "agent"` with `compose_prompt` (one LLM call,
  only when it fires). Great combined with a cheap probe: poll for free, and only let
  the model write the summary the moment the probe passes.

## Examples

- "avise quando o site x voltar":
  `{ action: "create", description: "site x back", trigger: "probe",
     probe_command: "curl -sf https://x.com", message: "✅ x.com voltou" }`
- "quando o deploy terminar, veja se subiu limpo e me avise":
  `{ action: "create", description: "deploy api", trigger: "probe",
     probe_command: "curl -sf https://api/health", notify: "agent",
     compose_prompt: "Check the last deploy logs and summarise the result in one line." }`

## Managing

- List active watches: `{ action: "list" }`.
- Pause / resume / cancel: `{ action: "pause" | "resume" | "cancel", id: "<id>" }` —
  e.g. the user says "para o watch do site" → list, find it, cancel it.

Creating a watch edits durable config, so it goes through the permission prompt.
Confirm the condition, how often to check, and what to send before creating.
