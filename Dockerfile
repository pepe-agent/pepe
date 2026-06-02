# Pepe as a container: a plain OTP release, not the Burrito binary.
#
#     docker run -d -p 4000:4000 -v pepe-data:/data \
#       -e PEPE_DASHBOARD_PASSWORD=a-strong-password ghcr.io/pepe-agent/pepe
#
# Two things are not optional here, and both bite silently if skipped:
#
#   * **The volume.** Config, agents, conversations and Mnesia all live in /data
#     (PEPE_HOME). Without `-v`, `docker rm` throws all of it away.
#
#   * **The dashboard password.** A container is not loopback, and PepeWeb.NetworkGuard
#     treats it as public: with no password every request gets a 403 (a posture adopted
#     after a real exposure incident). Set PEPE_DASHBOARD_PASSWORD or the dashboard
#     simply refuses to serve.
#
# ---------------------------------------------------------------------------------
# Giving the agent more tools
# ---------------------------------------------------------------------------------
# The agent runs as a non-root user, so it cannot `apt install`. That is deliberate,
# and it costs less than it looks, because root is not the missing key: **anything apt
# installs dies with the container** anyway - apt writes to /usr and /etc, which live in
# the container's writable layer, not in a volume. Root grants permission, not
# persistence. The question is never how to become root; it is where a tool has to live
# to survive. Two routes do that:
#
#   1. Anything the agent installs *for itself* goes to **/tools**, which is a volume,
#      is on the PATH, and is the agent's HOME. That last part is what makes it work:
#      installers do not ask where your volume is, they write to ~/.local/bin and
#      ~/.cache, and with HOME on the volume those land there by default. So `uv`, a
#      Whisper model, a `pip install --user`, or a plain
#
#          curl -sL <url> -o /tools/op && chmod +x /tools/op
#
#      all survive `docker rm` and a newer Pepe, with no root and no rebuild.
#
#   2. A system package (psql, imagemagick - things that scatter files and shared libs
#      across the filesystem) has to be in an image. No need to write one:
#
#          docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client" .
#
#      or derive from ours if you prefer a Dockerfile you keep:
#
#          FROM ghcr.io/pepe-agent/pepe
#          USER root
#          RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
#            && rm -rf /var/lib/apt/lists/*
#          USER pepe
#
# `docker exec -u root <container> apt-get install ...` works for a quick experiment,
# but it is gone on the next `docker rm` - use it to try, not to run.
#
# ---------------------------------------------------------------------------------
# Why a plain release, and why the pinned pair
# ---------------------------------------------------------------------------------
# Burrito exists to hand someone a single file that runs on *their* machine, with an
# ERTS bundled per OS. In an image the OS is already decided, so bundling one again is
# dead weight - PEPE_PLAIN_RELEASE tells mix.exs to skip Burrito and assemble a normal
# release instead.
#
# Builder and runner are pinned to the *same* Debian snapshot on purpose. The ERTS the
# release ships is linked against the builder's glibc, so a runner on an older Debian
# fails at boot with `version GLIBC_2.xx not found` - the image builds fine and then
# won't start. Bump these three together, never one alone.
#
# And keep them equal to what .github/workflows/{ci,release}.yml use. This image would run
# perfectly well on OTP 29, but the binaries cannot: Burrito 1.5.0 fails to build against
# it. Taking 29 here alone would put the image and the binaries of the same tag back on
# different runtimes, which is exactly the drift that hid a bug once already.
#
#   https://hub.docker.com/r/hexpm/elixir/tags

ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=28.5.0.3
ARG DEBIAN_VERSION=trixie-20260623-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# ---- build ----------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS build

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /src

ENV MIX_ENV=prod \
    PEPE_PLAIN_RELEASE=1

RUN mix local.hex --force && mix local.rebar --force

# Deps first: they change far less often than the code, so this layer survives
# most rebuilds.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config config
RUN mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib

# The dashboard is served from the release, so its CSS/JS must be built and
# digested into priv/static before the release is assembled.
RUN mix assets.setup && mix compile && mix assets.deploy

RUN mix release

# ---- runtime --------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runtime

# libstdc++/ncurses/openssl are what the ERTS in the release links against. The rest is
# for the agent itself: it has a `bash` tool and fetches URLs, so a runtime with no shell
# and no CA bundle would ship an agent that cannot work.
#
# ffmpeg is deliberately NOT here. It looks like it should be, since Telegram sends voice
# as OGG/Opus, but neither route that actually transcribes needs it: a transcription API
# takes the .ogg as it is, and faster-whisper decodes through PyAV, which carries its own
# codecs in the wheel. Debian's ffmpeg pulls 204 packages and 121MB of archives (LLVM,
# Mesa, a speech synthesizer, a theorem prover) to serve a GPU video stack that a headless
# container will never touch. If you want the whisper.cpp CLI, which does shell out to
# ffmpeg, add it with PEPE_IMAGE_APT_PACKAGES below or drop a static build in /tools.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates curl git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Extra system packages, without writing a Dockerfile of your own:
#
#   docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick" .
#
# For anything the agent installs by itself at run time, see /tools below - that is the
# route that does not need a rebuild.
ARG PEPE_IMAGE_APT_PACKAGES=""
RUN if [ -n "$PEPE_IMAGE_APT_PACKAGES" ]; then \
      apt-get update -y \
      && apt-get install -y --no-install-recommends $PEPE_IMAGE_APT_PACKAGES \
      && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Two volumes, on purpose.
#
# /data (PEPE_HOME) is *state*: config, agents, conversations, Mnesia. It is what you
# back up, and it is portable across machines.
#
# /tools is *cache*: everything the agent installs for itself. It is on the PATH, so a
# single-file CLI dropped there is immediately available to its shell, and it survives
# `docker rm` with no root and no rebuild. It is deliberately NOT inside /data, for two
# reasons: a backup should carry state, not tens of megabytes of regenerable binaries;
# and those binaries are architecture-specific, so a /data restored from an arm64
# machine onto an amd64 one would put executables that cannot run on the PATH.
#
# The agent's HOME is /tools/home, and that is what makes "install it once" actually
# hold. Installers do not ask where the volume is: `uv` lands in ~/.local/bin, a Whisper
# model in ~/.cache. With HOME in the container layer, every one of those is downloaded
# again on the next container, so the agent re-installs its transcriber on every voice
# message it ever gets. With HOME on the volume, it installs once. It sits under /tools
# rather than /data because that is exactly what it is: regenerable, architecture-bound,
# and no business being in a backup.
#
# /tools is appended to the PATH, never prepended. The agent can write there, so a
# prepended /tools would let it drop a file named `git` or `curl` in front of the
# real ones and have every later shell command - its own, and the operator's - run
# that instead. Appending still resolves the tools it installs, and cannot shadow a
# binary that is already on the system.
# A FIXED Erlang node name. The release otherwise defaults to `pepe@<hostname>`, and a container's
# hostname changes on every recreation (redeploy) - which orphans the Mnesia disc_copies store
# (`Pepe.Store`), since its table is bound to the node that created it. Pinning the node keeps the
# store loadable across restarts and redeploys. 127.0.0.1 stays inside the container (no clustering).
ENV PEPE_HOME=/data \
    PEPE_SERVE=1 \
    PORT=4000 \
    MIX_ENV=prod \
    RELEASE_DISTRIBUTION=name \
    RELEASE_NODE=pepe@127.0.0.1 \
    HOME=/tools/home \
    PATH=$PATH:/tools:/tools/home/.local/bin

WORKDIR /app

# Non-root: this agent runs shell commands an LLM chose, so don't hand it the box.
# Root would not even buy what it looks like it buys: `apt` writes to /usr and /etc,
# which are in the container layer, so what it installs dies with the container anyway.
# Durability comes from the volumes above, not from privilege.
RUN useradd --uid 1000 --home-dir /tools/home --create-home pepe \
  && mkdir -p /data /tools && chown -R pepe:pepe /data /tools /app

# Docker seeds a fresh named volume from the image, but only when it is empty, so a
# /tools volume created by an older image comes back without the home directory. Make
# sure it exists before the release reads $HOME.
COPY --chmod=0755 <<'SH' /usr/local/bin/pepe-entrypoint
#!/bin/sh
set -e
mkdir -p "$HOME" "$PEPE_HOME"
exec "$@"
SH

USER pepe

COPY --from=build --chown=pepe:pepe /src/_build/prod/rel/pepe ./

VOLUME /data /tools
EXPOSE 4000

# `start` runs the release in the foreground, which is what a container wants -
# no daemon, no supervisor, PID 1 is the VM and docker stop reaches it.
ENTRYPOINT ["/usr/local/bin/pepe-entrypoint"]
CMD ["bin/pepe", "start"]
