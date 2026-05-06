# Scheduled tasks (cron)

Run an agent on a recurring schedule (a daily report, a periodic check) and
deliver the result to a chat (or nowhere). A task fires in a **fresh session with
no chat memory**, so its prompt must be self-contained.

Three ways to create and manage them:

**1. From the CLI** (`mix pepe cron`):

```bash
mix pepe cron add \
  --name "Daily XML check" \
  --prompt "Check the 06:00 XML load and report anything abnormal." \
  --schedule "0 8 * * *" \
  --timezone America/Sao_Paulo \
  --deliver telegram:123456        # or omit / "none" to report nowhere
mix pepe cron list               # all tasks + next run time
mix pepe cron run daily-xml-check   # force it now (preview)
mix pepe cron logs daily-xml-check  # recent run history
mix pepe cron disable daily-xml-check
mix pepe cron remove daily-xml-check
```

The schedule is a standard 5-field cron expression; the timezone is any IANA name
(`America/Sao_Paulo`, `Europe/Berlin`, ...), so nothing is hard-coded. The default
timezone is set at `mix pepe setup` and used when a task doesn't name its own.

**2. From the dashboard.** The **Scheduled** tab lists every task with its next
run, a **Run now** button, enable/disable/remove, and a form to create one
(agent, prompt, schedule, timezone, model, and *where to deliver*, including
"Don't send anywhere"). Each task keeps a run history you can expand.

**3. By asking the agent in chat.** *"Every day at 8am Brasília time, check the
XML load and tell me here."* The agent creates the task with the `schedule_task`
tool (which must be in its allowlist), baking the context into the prompt. It's a
risky tool, so each use is authorized through the permission gate (or pre-approved).
When created from a chat, a task reports back to that same chat by default. The
agent can also `run` a task on demand from the conversation.

Tasks fire from an in-process timer that only runs while `mix pepe serve` or
`mix pepe gateway` is up (never during one-shot commands). Due tasks each run in
their own process, so they fire concurrently; one slow task never blocks another.
Definitions live in `~/.pepe/config.json` (`"crons"`); run history in
`~/.pepe/data/cron_logs/`.

---

[Back to the docs index](../README.md#documentation)
