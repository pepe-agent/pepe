---
title: Docker
description: Run Pepe as a container, and install the tools the agent needs inside it.
---

Every release publishes a container image alongside the binaries, for `amd64` and
`arm64`. `docker pull` selects the right architecture automatically, whether you are on
an M-series Mac or a server.

```bash
docker run -d --name pepe \
  -p 4000:4000 \
  -v pepe-data:/data \
  -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=a-strong-password \
  ghcr.io/pepe-agent/pepe
```

Open <http://localhost:4000>, sign in, and complete the setup from the dashboard.

## Requirements

Two settings are mandatory, and omitting either one fails silently.

### Volumes

There are two, and they hold different kinds of thing.

`/data` (`PEPE_HOME`) is **state**: configuration, agents, conversations, workspaces and
Mnesia. This is the volume you back up. Without it, `docker rm` deletes the entire
installation.

`/tools` is **cache**: everything the agent installs for itself. It is on the `PATH`, and
it is also where the agent's home directory lives, at `/tools/home`. That second detail is
what makes "install it once" actually hold, and it has a section of its own below.

`/tools` is kept out of `/data` on purpose. A backup should carry state, not tens of
megabytes of binaries and model files that can be downloaded again, and those files are
architecture-specific: a `/data` backed up on an arm64 machine and restored on an amd64
one would put executables on the `PATH` that cannot run there.

```bash
-v pepe-data:/data -v pepe-tools:/tools
```

### Dashboard password

A container is not loopback. Pepe classifies it as a public network and, without a
password, returns 403 to every request: the dashboard will not serve.

```bash
-e PEPE_DASHBOARD_PASSWORD=...
```

This is a deliberate policy, not a Docker limitation. Pepe refuses to expose an
unauthenticated dashboard on a network it cannot vouch for. The policy came out of a
real incident, where an exposed service with no authentication was scanned and abused.

## Secrets

Do not put API keys in the image or in the configuration file. Keep only the reference
in the configuration and supply the real value at run time. Pepe resolves the reference
when reading and never stores the expanded value.

```bash
# the configuration holds only:  "api_key": "${OPENROUTER_API_KEY}"
docker run -d ... -e OPENROUTER_API_KEY=sk-... ghcr.io/pepe-agent/pepe
```

## Installing tools for the agent

The agent runs as an unprivileged user and cannot run `apt install`. This is intentional:
the commands it executes are chosen by a language model, and granting that root is not a
decision to make on your behalf.

The restriction costs less than it appears, because root is not the missing key:

> Anything `apt` installs dies with the container. apt writes to `/usr` and `/etc`, which
> belong to the container's writable layer, not to a volume. Root grants permission, not
> persistence. What it installs is gone on `docker rm` even when you do run as root.

The question is never how to become root. It is where a tool has to live in order to
survive. There are two answers, and the first one now covers most cases on its own.

### Anything the agent installs for itself persists

The agent's `HOME` is `/tools/home`, which puts it inside the `/tools` volume. This is the
whole trick. Installers do not ask where your volume is: they write to `~/.local/bin` and
`~/.cache`, and nowhere else. With `HOME` in the container layer, everything the agent
sets up for itself is downloaded again in the next container. With `HOME` on the volume,
it installs once.

The difference is easy to measure. An agent that transcribes a voice message installs `uv`
and pulls down a Whisper model, about 75 MB of it. The first run takes 27 seconds. In a
brand new container, the same transcription takes 1.2 seconds, because the cache survived.

So `uv`, a `pip install --user`, a Whisper model, a language toolchain, or a plain
download:

```bash
curl -sL <url> -o /tools/op && chmod +x /tools/op
```

all survive `docker rm` and a Pepe upgrade, with no root and no rebuild. `/tools` is on
the `PATH`, so a single binary dropped there is callable from the agent's shell straight
away. The 1Password CLI (`op`), `gh`, `kubectl` and `terraform` are all single files and
need nothing more than this.

### System packages go in the image

Some tools are genuine system packages. `psql`, `imagemagick` and their kind scatter files
and shared libraries across the filesystem, and a volume cannot hold that. They have to be
part of an image.

A build argument installs extra packages without you writing a Dockerfile at all:

```bash
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick" .
```

If you would rather keep a Dockerfile of your own, deriving from the image works just as
well and stays a perfectly good option:

```dockerfile
FROM ghcr.io/pepe-agent/pepe
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client \
  && rm -rf /var/lib/apt/lists/*
USER pepe
```

```bash
docker build -t my-pepe .
docker run -d -p 4000:4000 -v pepe-data:/data -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=... my-pepe
```

Either route carries the same trade-off: every new Pepe release means rebuilding the
image.

#### Why `ffmpeg` is not in the image

`ffmpeg` looks like the obvious system package for this image, since Telegram sends voice
as OGG/Opus and a transcript has to come from somewhere. Neither of the two routes that
actually transcribe needs it. A transcription API takes the `.ogg` exactly as it arrives,
with no conversion at all, and `faster-whisper` decodes through PyAV, which carries its own
codecs inside the wheel. That was measured rather than assumed: an OGG/Opus file
transcribed on a clean Debian with no `ffmpeg` installed anywhere. Only the `whisper.cpp`
CLI shells out to `ffmpeg`, and that route is opt-in.

Shipping it anyway cost far more than it was worth. Debian's `ffmpeg` package drags in 204
packages and 121 MB of archives (LLVM, Mesa, a speech synthesizer, a theorem prover), all
to serve a GPU video acceleration stack that a headless container will never touch.
Dropping it took the image from 945 MB to 408 MB, roughly 84 MB compressed, which is what
you actually pull per architecture.

If you do want `ffmpeg`, for the `whisper.cpp` CLI or for anything else, install it with
the build argument above, or drop a single-file static build into `/tools`, which is on the
`PATH` and lives on a volume.

### Trying a tool out

```bash
docker exec -u root pepe apt-get update
docker exec -u root pepe apt-get install -y jq
```

This works, and it is discarded on the next `docker rm`. Use it to confirm a tool solves
your problem, then decide where it belongs: the agent's own home if it can install it
itself, the image if it is a system package.

Running the container as root (`docker run --user root`) is opt-in and never the default.
It is worth repeating that it buys nothing durable: what `apt` writes still dies with the
container, so you end up back at the two answers above.

## Compose

```yaml
services:
  pepe:
    image: ghcr.io/pepe-agent/pepe:latest
    restart: unless-stopped
    ports:
      - "4000:4000"
    volumes:
      - pepe-data:/data
      - pepe-tools:/tools
    environment:
      PEPE_DASHBOARD_PASSWORD: ${PEPE_DASHBOARD_PASSWORD}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY}

volumes:
  pepe-data:
  pepe-tools:
```

```bash
docker compose up -d
```

## Upgrading

```bash
docker pull ghcr.io/pepe-agent/pepe
docker rm -f pepe
docker run -d ... ghcr.io/pepe-agent/pepe   # same volumes, same flags
```

Configuration, agents and conversations come back with `/data`. The agent's tools, its
home directory and every cache in it come back with `/tools`, so it does not reinstall
anything on the first message. Packages installed with `apt` do not come back, which is
why the image exists for those.

## A shell into the node

```bash
docker exec -it pepe bin/pepe remote
```

Opens an IEx shell attached to the running release, for inspecting the system from the
inside.
