---
title: Voice messages
description: A voice note arrives as text. Transcription happens at ingestion, before the agent runs.
---

## Voice messages

Send a voice note to your Telegram bot and the agent receives **text**. The audio is
transcribed on the way in, before a session exists and before any routing decision is
taken, so what reaches the agent is an ordinary message.

It did not always work that way. The gateway used to save the file into the agent's
workspace and hand over the path, leaving the agent to work out how to listen: find a
transcriber, install it, run it, read the output. Every voice note turned into a small
research project. It was slow, it came out different each time, and it spent a permission
prompt on the mere act of reading the message that had just arrived.

### Nothing to configure

If you already have a model connection to OpenAI or Groq, transcription already works.
Pepe reuses that credential and asks the provider for its transcription model
(`whisper-1` on OpenAI, `whisper-large-v3-turbo` on Groq) instead of the chat model the
connection was configured with. Send a voice note and it gets answered. There is nothing
to set up.

### How the route is chosen

Pepe tries these in order, and any of them may be missing:

1. **`media.audio.model`**: a model connection, referenced by name. That connection's own
   `fallbacks` chain applies here too, so failover costs nothing extra.
2. **`media.audio.command`**: a local command, such as `whisper-cli -f {file}`. `{file}`
   is replaced with the path to the audio. This is tried *before* automatic detection, on
   purpose: a machine that configured a local transcriber did so to keep audio off the
   network, and reaching past it to a provider would defeat the point.
3. **Automatic detection**: the zero-config route described above.
4. **Nothing available**: the file goes to the agent, which works it out with the tools it
   has. That path stays as a safety net; it is not the way in.

### Configuring it

Point transcription at a specific model connection, or a local command, from the CLI:

```bash
pepe media audio --model groq --language en --echo true
pepe media audio --command "whisper-cli -f {file}"   # keep audio on the machine
pepe media audio off                                 # back to auto-detect
```

`--echo true` sends the transcript back to the chat so the speaker can see what was
understood. The same settings are on the dashboard's Config page, and in `pepe setup`
under **Media**.

### Why transcribing first matters

Because the words exist before routing runs, routing can read them. Two things follow, and
neither was possible while the transcript only appeared inside the agent's turn:

- **A spoken slash command runs.** Say `/help` or `/stop` into a voice note and the
  command executes, exactly as if you had typed it, rather than becoming an agent turn
  about a file sitting in a directory.
- **A bot in a group can be addressed by voice.** In a group that requires a mention, the
  gate reads the **words** rather than the caption. A voice note carries no caption, so
  before this there was nothing for the gate to read, and addressing the bot out loud was
  impossible.

<div class="note"><strong>Audio becomes text; a photo becomes sight.</strong> Speech is
transcribed at the door. A photo is sent to the model as an image it can actually see (on a
vision model, see below). A document is extracted to text.</div>

## Talking back

Reply to a voice note with a voice note. Off by default; point `media.tts` at a model
connection serving an OpenAI-compatible `/audio/speech` and it turns on:

```bash
pepe media tts --model openai --voice nova
pepe media tts off
```

The text reply is still what's saved as the lasting record - the audio is an extra, and
it's length-capped so a long answer never becomes a five-minute clip. A TTS failure is
silent: the text reply already went out, so nothing is lost, it just doesn't get a voice
that turn. Same settings on the dashboard's Config page, and in `pepe setup` under
**Media**.

## Photos

Send a photo to your Telegram bot and, on a **vision-capable model**, the agent sees the
actual image, not a filename. It used to receive only a line of text ("the user sent a photo,
saved at `…`") while the picture itself never reached the model, so the agent was left
guessing at, or inventing, what was in it. Now the image rides along with the message.

It is off unless you say the model can see. Not every OpenAI-compatible endpoint accepts an
image, and sending one to a text-only model is an error, so vision is opt-in per connection:

```json
{
  "models": {
    "gpt4o": {
      "base_url": "https://api.openai.com/v1",
      "api_key": "${OPENAI_API_KEY}",
      "model": "gpt-4o",
      "vision": true
    }
  }
}
```

With `vision` set, a photo (with or without a caption) reaches the model as an image on the
turn it arrives. It works the same on OpenAI-compatible, Anthropic, and Responses/Codex
connections. The image rides that one turn only: like a transcript, the lasting record is the
agent's reply about it, not the bytes, so it never bloats the session or gets re-sent every
turn. A model without `vision` falls back to the old behaviour (the file path in the prompt,
for the agent to open with its own tools).

Telegram already sends each photo in several pre-scaled sizes, so Pepe picks the largest that
fits the byte cap, with no image-processing library to install. An album of photos is sent as
several images together. The limits live under `media.image` and both have defaults:

- `max_mb`: the largest image accepted, in megabytes. Defaults to `5`. An oversized photo (or
  one of an unsupported type) falls back to the file-path prompt instead.
- `max_parts`: how many images one turn may carry, for albums. Defaults to `4`. Anything past
  that is handed over as a file path.

```json
{
  "media": {
    "image": { "max_mb": 5, "max_parts": 4 }
  }
}
```

### Configuration

Every key is optional and lives under `media.audio` in `~/.pepe/config.json`:

- `model`: the name of a model connection to transcribe with.
- `command`: a local transcriber. `{file}` is replaced with the path to the audio.
- `language`: a language hint passed to the provider.
- `max_mb`: size limit for an inbound file. Defaults to `20`.
- `timeout`: how long a transcription may take, in seconds. Defaults to `60`.
- `echo`: send the transcript back to the chat as `📝 ...`, so the speaker can check what
  was understood.

```json
{
  "media": {
    "audio": {
      "model": "groq",
      "language": "en",
      "max_mb": 20,
      "timeout": 60,
      "echo": true
    }
  }
}
```

To keep the audio on the machine, use a command instead of a connection:

```json
{
  "media": {
    "audio": {
      "command": "whisper-cli -f {file}",
      "timeout": 120
    }
  }
}
```

### Guards

- **A file under 1 KB is refused before any request is made.** At that size it is empty or
  truncated rather than quiet, and no transcriber would say anything useful about it.
  Refusing costs nothing; sending it costs a request.
- **A file over `max_mb` is refused the same way**, before it costs a request.
- **A wedged command is abandoned at `timeout`** instead of hanging the conversation behind
  it.
- **Audio with no speech in it gets a short reply**, not an agent turn. The file was read,
  it just had nothing in it, and answering an empty message would only produce a confused
  reply.
