---
title: Documents
description: A file sent in a chat arrives as text, read at the door, together with whatever was said about it.
---

## A document is a message, not a research task

Send a PDF with the caption "summarise this" and it should read as one message. It does. The file is read when it arrives, before routing, so the model is handed the instruction and the material together and answers about the content instead of first having to go and find it.

The agent *can* do this itself, and until now it had to: identify the file, choose a library, install it, write a script, run it. That works, and it costs several turns, it comes out differently every time, and it needs the agent to hold `bash`, which an agent facing a client must never hold. That route is still there, as the safety net. It is no longer the way in.

## What is read, and what it costs

| | |
|---|---|
| **Text** (`.txt`, `.md`, `.csv`, `.json`, `.log`, `.xml`, and their kind) | Nothing. The file is read. |
| **`.docx`, `.xlsx`, `.pptx`** | Nothing either. They are ZIP archives of XML, and Erlang already unzips. No Python, no system package, no bytes on the image. |
| **`.pdf`** | `pdftotext` where the machine has it. Where it does not, the agent falls back to working it out and installing what it needs, once. |
| **Anything else** | Falls through to the agent, which is what used to happen for everything. |

The spreadsheet is the one worth explaining. Stripping the tags out of an `.xlsx` produces something that *looks* like an answer: a wall of the words that were in it, with the numbers gone and the rows collapsed into each other. Excel stores repeated strings once, in a shared table, and a cell holds an index into it, so a naive read hands the model a list of indices masquerading as data. It would answer confidently and wrongly, and nobody would know. So the cells are actually read, and a sheet arrives as rows and columns.

## Long documents

Only the first part of a long document is handed over, so one attachment cannot eat the context window. The whole file stays in the agent's workspace and the agent is told where, so when it needs the rest it reads the rest.

## Archives are not opened

A `.zip` or a `.tar.gz` is a box, not a document. There is no "the text" of it, and unpacking whatever a stranger sends you is how you accept a decompression bomb and a path traversal in the same gesture. It falls through to the agent, which opens it deliberately, at the permission gate, and looks at what is inside before acting on it.

The office formats are safe precisely because they are **not** general: one entry is read, by name, into memory, and nothing is ever written to disk.

<div class="note"><strong>Sending one is a different thing.</strong> Asking an agent to zip a folder and send it back works today: it builds the archive with <code>bash</code> and delivers it with <code>send_file</code>, on whatever channel the conversation is on. Creating something you asked for is not the same as opening something a stranger sent.</div>
