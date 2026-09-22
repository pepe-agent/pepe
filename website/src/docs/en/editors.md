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

**Your conversation persists.** Closing the editor does not end it. Every ACP conversation is saved the same way a Telegram or dashboard conversation is, so your editor's history panel can list past sessions, reopen one where you left off, or pick up one you started in a different project directory. Two editor windows can't silently step on the same conversation: if one is already open elsewhere, you're told so and offered a fork instead, which continues from the same point under a new, separate id. Sessions you haven't touched in 30 days, or the oldest ones past 200, are cleaned up automatically; nothing that's still open is ever swept.

**Slash commands, right in the chat panel.** Type `/status`, `/rewind 2`, `/model`, `/usage` and the rest, the same commands and the same answers you'd get on Telegram or in `mix pepe chat` - they show up in your editor's command palette with their own descriptions. A few, like `/rewind` and `/undo`, rewrite the conversation and wait for a turn in progress to finish first; others, like `/status` and `/steer`, work at any time. Anything you type that isn't one of these just goes to the agent as an ordinary message.

**A plan panel and a context meter, when the agent uses them.** A multi-step task the agent tracks with its own planning tool shows up as a checklist in the editor, updated as steps complete. After each reply, the editor also learns how much of the model's context window the conversation is using, the same number `/context` prints.

**Switching models or how much it may do without asking, mid-conversation.** Your editor's own settings for this session (not `pepe agent add`, not `config.json`) let you pick from the models already configured for this agent, and choose an edit-approval mode: ask before every file change (the default), let edits inside the project go through without asking, or let edits anywhere go through without asking. A sensitive path, a policy-escalated call, or anything once the conversation has taken in outside content still asks regardless of mode - modes only ever relax the file-edit prompt, never any other permission check.

**Images, audio, and files brought into the prompt with `@`.** What actually gets used depends on the agent you're talking to: an image is handed to a vision-capable model as an image and refused with a clear reason for one that can't see; a voice note is transcribed if you have a transcription route configured (see [Voice](../voice/)); embedded file context (what your editor sends when you `@`-mention a file) always works. Nothing is silently dropped - a block the agent can't use is reported back to you, not thrown away.

**MCP servers configured in the editor.** If your editor is set up to hand your agent MCP servers for this project, Pepe now uses them for that conversation only - never written to `config.json`, never available to any other session, channel or agent, and stopped the moment the editor disconnects. A server that fails to start doesn't stop the conversation; you're told, and the rest still works. Configure servers on the agent itself instead, with `pepe mcp add`, when you want them available everywhere. See [MCP](../mcp/).

### Setting up a model connection from inside the editor

`session/new` on an agent with no usable model connection fails right away and tells your editor to offer authentication, so you're never left staring at a connection that opens fine and then errors on the first message. There's nothing to log into (Pepe authenticates to your model provider from its own configuration, not the editor's), so what's actually offered is a choice of two ways to fix it: use the model connections you've already configured in Pepe, if you have any, or open a terminal that runs Pepe's interactive setup (`pepe acp --setup`) to add one.

### What it does not do, and why

**Reading files and running terminals through the editor.** The agent already has its own tools for both, running on the same machine, so routing them back through the editor would only create a second set of rules to keep in agreement with the first.

**Asking you a follow-up question mid-tool-call (elicitation).** Every question Pepe needs answered from a person is either a permission prompt or a message in the conversation - there's no third kind of interruption to build a separate UI for.

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
