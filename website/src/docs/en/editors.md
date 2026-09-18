---
title: Code editors
description: Connect a Pepe agent to your editor over the Agent Client Protocol.
---

## Your agent, inside your editor

Editors have learned to talk to agents the way they already talk to language servers: they start one as a small background process and exchange messages with it. The protocol for that is the [Agent Client Protocol](https://agentclientprotocol.com), an open standard that is not tied to any one editor or any one agent.

Pepe speaks it. Point your editor at one command and the agent you already configured answers in the editor's own chat panel, with its tools, its memory, its skills and its permissions. Nothing is duplicated: it is the same agent that answers on Telegram, on the web dashboard and in the console.

### Start it

```bash
pepe acp                 # the default agent
pepe acp support         # a named agent
pepe acp --project acme  # that project's default agent
```

You will rarely type this yourself. Your editor runs it for you, as a child process, and talks to it over its input and output. What you configure in the editor is that command line.

Look in your editor's settings for external, custom or ACP agents, and give it the command above. If your editor asks for the command and its arguments separately, the command is `pepe` and the argument list is `["acp"]`, plus an agent name if you want a specific one.

**Running from source?** The command is `MIX_QUIET=1 mix pepe acp`. The `MIX_QUIET=1` matters: the protocol allows nothing on the output except its own messages, and without it the build tool's own "Compiling..." line lands there and confuses the editor.

### What you get

**The answer as it is written.** Text streams into the editor's panel as the agent produces it, the same as in the console.

**Every tool call, as it happens.** When the agent reads a file, runs a command or searches the web, the editor shows the call and then its result. You see the actual arguments, not just a name.

**A real permission prompt.** This is the part worth having. When the agent wants to do something that needs your say-so, the editor asks you, right there, with the exact command in front of you and the same set of answers you would get anywhere else:

- allow once
- allow everything for this task
- allow for this session
- always allow
- don't allow

Your answer means exactly what it means everywhere else in Pepe. "Always allow" writes the same standing permission that answering on Telegram would, scoped to what you were actually looking at rather than to the tool's name. If the task has read something from outside the conversation, your earlier standing approvals are set aside for it and the agent asks again, which is why the recommended answer changes in that situation. See [Security](../security/) for what each answer covers.

**Cancelling.** Stop the turn from the editor and the agent stops, including while it is waiting on a permission prompt nobody answered.

### What it does not do, and why

Pepe implements the heart of the protocol and reports honestly, during the initial handshake, which parts it left out, so your editor never offers you something that will not work:

**Picking up an old conversation.** A session lives as long as the editor keeps the process running. Close the editor and it is gone. Your longer-lived conversations live on the channels built for that.

**Logging in.** There is nothing to log into. Pepe authenticates to your model provider using its own configuration.

**Images, audio and file attachments in the prompt.** Text only, for now. You can still point the agent at a file by mentioning it: the agent can read it itself.

**MCP servers configured in the editor.** If your editor is set up to hand MCP servers to the agent, Pepe refuses the connection rather than accepting it and quietly not using them. Configure them on the agent instead, with `pepe mcp add`, and they work on every channel at once. See [MCP](../mcp/).

**Reading files and running terminals through the editor.** The agent already has its own tools for both, running on the same machine, so routing them back through the editor would only create a second set of rules to keep in agreement with the first.

### What the agent may do

Everything the agent can reach here is its own configuration, not the editor's. `pepe agent list` shows which tools it holds and `pepe tools` shows what exists. An agent with no `bash` will not run commands from your editor either, and one with `bash` will ask you before it does.

If you want an editor-facing agent that is narrower than your everyday one, make a second agent and point the editor at that:

```bash
pepe agent add reviewer --prompt "You review code. Be brief." --tools read_file,list_dir
pepe acp reviewer
```

### Related

- [Security](../security/) covers what each permission answer actually grants.
- [Agents](../agents/) covers creating and shaping the agent this connects to.
- [HTTP API](../api/) is the other way to reach an agent from your own program.
