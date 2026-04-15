---
title: Skills
description: Install reusable instructions that teach agents repeatable workflows.
---

Skills are reusable Markdown instructions that teach an agent how to perform a workflow. They live in `priv/skills/` for built-ins and can be installed so agents can discover and apply them during a run.

## The registry: how tools are found

`Pepe.Tools` is the single registry. It combines two sources.

- The **built-in** set, a fixed list in `Pepe.Tools`. It includes `bash`,
  `run_script`, `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir`,
  `fetch_url`, `web_search`, `send_file`, and the management tools an agent uses
  to run the runtime by chat (`manage_agent`, `manage_channel`, `enable_tool`,
  `schedule_task`, and others).
- **Plugins**, discovered at runtime from the plugins folder.

`Pepe.Tools.all/0` returns the built-ins followed by every loaded plugin tool.
When you list an agent's tools, each name is looked up here. There is one rule to
know: on a name collision, the built-in wins. You cannot shadow `read_file` with
a plugin of the same name, so pick a distinct name for your tool.

### Granting a tool to an agent

A plugin being installed does not automatically hand its tools to every agent.
Only the tools you list on an agent are exposed to it, and each call still
passes through the same permission gate as a built-in tool. You grant a tool
three ways.

**With the pepe CLI.** List the tool in the agent's `--tools`:

```bash
pepe agent add assistant --tools reverse_text,web_search,read_file
```

**On the dashboard.** Open the agent under Agents and tick the tool in its tool
list. The plugin's tools appear alongside the built-ins.

#### Do it by chat

An agent that has the `enable_tool` built-in can turn a tool on for itself
after you install a plugin, without you touching the CLI or dashboard.

> You: enable the reverse_text tool
>
> Agent: enabled reverse_text; you can use it from your next message

`enable_tool` only accepts a tool that already exists as a built-in or a loaded
plugin, and the change takes effect on the agent's next message. To grant a tool
to a *different* agent, an agent with the `manage_agent` tool can do it with the
`add_tool` action. That tool is scoped to the agents the acting agent is allowed
to manage, and its instructions tell it to confirm the change with you before
applying it.

> You: give the support agent the gmail_search tool
>
> Agent: I will add gmail_search to the "support" agent. Confirm?
>
> You: yes
>
> Agent: added gmail_search to support.
