Use when you're told a media file (voice/audio, image, document) was saved in your workspace at some path.

You can't "hear" or "see" the file directly — but you have `bash`, `run_script`, and
file tools, and you may install whatever you need. So **figure out what the file is,
pick a way to understand it, install the missing pieces, and do it.** The user
approves anything risky through the permission prompt.

General loop for any unsupported input:
1. Identify the type (extension / the instruction you were given).
2. Choose a method (an API you're configured for, or a local tool).
3. If a needed tool/lib is missing, **install it**, then proceed.
4. Run it, read the result, and respond to the actual content.
5. If it's a recurring need, **save the script** (`scripts/…`) so next time is instant.

## Voice / audio → transcribe it

Prefer whichever is available:

**A) A transcription API** — if a model connection exposes an OpenAI-style
`/audio/transcriptions` endpoint (e.g. whisper-1, gpt-4o-transcribe), POST the file
to it and use the text. Cheapest when you already have the key.

**B) Local transcription** with `faster-whisper` (Python). This is the fully
self-contained path. Use [[write-a-script]]:

```bash
# Ensure a Python runner exists. uv gives you Python with no system install:
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
```

```python
# scripts/transcribe.py  — run: uv run --with faster-whisper python scripts/transcribe.py <path>
import sys
from faster_whisper import WhisperModel
model = WhisperModel("base", device="cpu", compute_type="int8")
segments, _ = model.transcribe(sys.argv[1])
print("".join(s.text for s in segments).strip())
```

Run it with `run_script` (or bash): `uv run --with faster-whisper python scripts/transcribe.py media/voice_123.ogg`.
The first run downloads uv + the model; later runs are fast. If decoding the `.ogg`
fails, install `ffmpeg` and retry. Then **reply to what the transcript says**, in the
user's language — don't just echo the transcript.

## Images → look at them

If your model accepts image input, pass the file. Otherwise describe it with a local
tool you install (e.g. an OCR/vision lib via `uv run --with …`). Same loop.

## Documents (PDF, spreadsheet, …)

Handle with [[write-a-script]] — read/parse with the right library (`pypdf`,
`openpyxl`, …), installing it on the fly, and answer about the content.

## Notes
- Files the gateway saved live under `media/` in your workspace; scripts run there,
  so relative paths just work.
- Save reusable scripts under `scripts/` and re-run them with `run_script file:`.
- If you genuinely can't install what's needed (offline, install denied), say so
  plainly and suggest what the user could enable.
