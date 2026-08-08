---
title: Deploying to a server
description: Put Pepe on a server of its own, with a domain name and HTTPS, using Docker Compose, Docker Swarm or Kamal.
---

[Docker](/en/docs/docker/) covers the container itself. This page covers the step after
that: putting it on a machine other people reach, behind a domain and a certificate.

Whichever tool you use, the container is the same one and so are the two volumes. What
changes is everything around it, and the parts that change are not obvious, because
locally they are all defaults you never had to think about.

## Four things that change the moment it leaves localhost

**A dashboard password becomes mandatory.** It already was in Docker, and the reason is
the same one here: to Pepe, only requests coming from the machine itself count as private
(loopback); everything else is the public network, and without a password every such
request is refused with a 403. Behind a reverse proxy that is *every* request.

**`PHX_HOST` is the public name.** Pepe builds absolute URLs from it: widget embeds and
the webhook URLs you hand to Telegram or WhatsApp. Left unset it is `localhost`, and
those URLs are quietly wrong while everything else works.

**`SECRET_KEY_BASE`, or everyone is logged out on every deploy.** Unset, Pepe generates a
random one at each boot, which is fine for a one-off container and wrong for a server:
after each deploy nobody's login is recognized anymore (the session cookies were signed
by the old secret), and everyone signs in again. Generate it once
(`openssl rand -base64 48`) and keep it.

**Two settings live only in `config.json`.** They have no environment variable, so they
are applied after the first boot rather than passed in. The container's own `pepe` CLI
dispatch only runs for the Burrito binary, not this plain release, so reach it through
`bin/pepe rpc`, calling `dispatch_attached/1` (safe against a node that's already
serving, see [Docker](/en/docs/docker/#a-shell-into-the-node)):

```bash
docker exec -it <container> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "hosts", "agents.example.com"])'
docker exec -it <container> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "trusted-proxies", "10.0.1.0/24"])'
```

`allowed_hosts` names the domains Pepe should answer to. With a password set and no
allowlist, Pepe accepts any `Host` header, because the password is the gate and it has no
way to know which domain you meant; naming yours closes an attack called DNS rebinding,
where a malicious page tricks a browser into reaching your Pepe under a different name.
`trusted_proxies` is the one people skip and then misdiagnose: left empty, every
`X-Forwarded-For` header is ignored, so the login rate limiter cannot tell visitors
apart, sees the proxy's address for everybody, and the whole internet shares one bucket.
Use the network your proxy actually sits on, not `0.0.0.0/0`. Trusting every forwarding
header is the same as having no limiter at all.

<div class="note"><strong>One replica. Always.</strong> Of the two stores Pepe keeps on that volume, the risk is not really the state on it. It is that a second instance runs a second scheduler, and every cron, watch and commitment fires twice (the <a href="#the-one-default-to-change">Kamal section</a> works through this, and it applies to every tool here). Two containers on two volumes are worse in a quieter way: two different Pepes, each convinced it is the only one. Every example below pins a single replica, and where the orchestrator's default is to start the new container before stopping the old one, that is turned off too.</div>

## Docker Compose, behind Caddy

The smallest thing that works on a single machine. Caddy gets the certificate on its own,
with no configuration beyond the domain name.

```yaml
# compose.yml
services:
  pepe:
    image: ghcr.io/pepe-agent/pepe:latest
    restart: unless-stopped
    volumes:
      - pepe-data:/data
      - pepe-tools:/tools
    environment:
      PEPE_DASHBOARD_PASSWORD: ${PEPE_DASHBOARD_PASSWORD:?set this in .env}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:?set this in .env}
      PHX_HOST: agents.example.com
      TZ: UTC
    # No `ports:`. Only Caddy is published; Pepe is reachable on the internal network
    # and nowhere else, so nobody can bypass TLS by hitting the host on :4000.
    expose:
      - "4000"

  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
    depends_on:
      - pepe

volumes:
  pepe-data:
  pepe-tools:
  caddy-data:
```

```caddyfile
# Caddyfile
agents.example.com {
	reverse_proxy pepe:4000
}
```

```bash
docker compose up -d
```

That is the whole reverse proxy. Caddy requests the certificate on first request and
renews it; `caddy-data` is where it keeps them, so do not delete that volume casually or
you will re-request certificates and can hit Let's Encrypt's rate limit.

## Docker Swarm, behind Traefik

If you already run a Swarm with Traefik, Pepe joins it like any other service. Two things
differ from a normal stack, and both are about the state on that volume.

```yaml
# pepe-stack.yml, deployed with: docker stack deploy -c pepe-stack.yml pepe
services:
  pepe:
    image: ghcr.io/pepe-agent/pepe:latest
    volumes:
      - pepe_data:/data
      - pepe_tools:/tools
    environment:
      PEPE_DASHBOARD_PASSWORD: "${PEPE_DASHBOARD_PASSWORD:?}"
      SECRET_KEY_BASE: "${SECRET_KEY_BASE:?}"
      PHX_HOST: agents.example.com
      TZ: UTC
    networks:
      - network_public
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:4000/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      # The BEAM plus the migrations on boot. A health check that fires too early puts
      # the task in a restart loop that looks like a crash.
      start_period: 90s
    deploy:
      replicas: 1
      update_config:
        # Swarm's default starts the new task before stopping the old one, which would
        # put two Pepes on one volume for the length of a deploy.
        order: stop-first
        failure_action: rollback
      rollback_config:
        order: stop-first
      placement:
        # Local volumes do not follow a task to another node.
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.pepe.rule=Host(`agents.example.com`)"
        - "traefik.http.routers.pepe.entrypoints=websecure"
        - "traefik.http.routers.pepe.tls=true"
        - "traefik.http.routers.pepe.tls.certresolver=letsencryptresolver"
        - "traefik.http.services.pepe.loadbalancer.server.port=4000"
        - "traefik.docker.network=network_public"

networks:
  network_public:
    external: true

volumes:
  pepe_data:
  pepe_tools:
```

In Swarm the Traefik labels go under `deploy.labels`, not the service's own `labels:`.
Put them in the wrong place and Traefik simply never sees the service: no error, just a
404 for that host.

```bash
export PEPE_DASHBOARD_PASSWORD='...' SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker stack deploy -c pepe-stack.yml pepe
```

## Kamal

Kamal deploys Pepe as the application. There is nothing to compile, so the Dockerfile is
one line. It exists so Kamal has something to build and push to your own registry, and it
is also where system packages go if the agent ends up needing any:

```dockerfile
# Dockerfile
FROM ghcr.io/pepe-agent/pepe:0.10.2
```

Pin a version rather than `latest`. Kamal rebuilds on every deploy, and `latest` would
mean a deploy of your own unrelated change quietly brings a new Pepe with it.

```yaml
# config/deploy.yml
service: pepe
image: your-user/pepe

servers:
  web:
    # One host. See the note below.
    - 203.0.113.10

proxy:
  ssl: true
  host: agents.example.com
  app_port: 4000
  healthcheck:
    path: /healthz

env:
  clear:
    PHX_HOST: agents.example.com
    TZ: UTC
  secret:
    - PEPE_DASHBOARD_PASSWORD
    - SECRET_KEY_BASE

volumes:
  - /opt/pepe/data:/data
  - /opt/pepe/tools:/tools
```

```bash
kamal setup     # first time
kamal deploy    # after that
```

Kamal's proxy terminates TLS and gets the certificate from `proxy.host`.

### The one default to change

Kamal deploys without downtime by design: it starts the new container, waits for it to
answer the health check, switches traffic to it, and only then stops the old one. For an
application whose database lives somewhere else, that is exactly right.

For those few seconds two Pepes are up at once. The new one is not serving anything yet,
which sounds harmless, and for requests it is: the proxy has not switched. But a scheduler
does not wait to be asked.

**Cron jobs, watches and commitments fire in both.** Each instance starts its own scheduler
at boot, ticking every 30 seconds against the same `config.json`, and the claim that stops
one job from running twice is in-memory state inside that scheduler process. A second
process has its own, empty. So anything that comes due in the overlap runs twice: two agent
turns billed, two messages delivered. Pepe's own supervisor says as much, in a parenthesis:
*run a single long-lived surface at a time, two schedulers on one config double-fire.*

The stores on the volume are less dramatic than they look, for the record. SQLite is opened
WAL with a busy timeout and would most likely cope. The Mnesia store can be reset by
whichever instance finds it unloadable, but it is the disposable tier by design: TTL'd
session context and dedup keys, so you lose the thread of open conversations, not anything
you configured. And `config.json` only loses a write if the old instance happens to be
making one at that exact moment, which needs traffic it is about to stop receiving.

**Whether that matters depends on what you run.** Two questions, and if both answers are no,
keep the zero-downtime deploy and ignore this section: does anything fire on a schedule
(crons, watches, commitments), and is a Telegram gateway configured? Telegram is the one
that does not need luck: both instances poll the same bot token, one gets a `409`, and a
message can be picked up by the instance that is about to be stopped. That happens on every
deploy, not on some of them.

If either applies, stop the app first and take the short gap:

```bash
kamal app stop
kamal deploy
```

If a gap is not acceptable, run Pepe as a Kamal **accessory** instead. `kamal accessory
reboot pepe` stops the old container before starting the new one, with no overlap, and an
accessory is never load balanced. That is also the natural shape when Pepe is going
*beside* an application you already deploy with Kamal, rather than being the deployment
itself.

## Health checks

`/healthz` (or `/health`) answers 200 as soon as the app is up, and it is deliberately
exempt from the HTTPS redirect so a proxy can reach it over plain internal HTTP.

Give it a generous start period. Pepe runs its migrations at boot, and a check that
starts probing after 10 seconds on a loaded host will kill a container that was about to
be fine.

## Do not put HTTP basic auth in front

It is a natural instinct for a service on a domain, and it breaks three things at once.
The dashboard already has its own password with a login page and a rate limiter, so the
basic auth adds nothing there, but it also sits on `/v1`, on the webhook endpoints
Telegram and WhatsApp POST to, and on the chat widget's WebSocket. All three carry their
own credentials and none of them can answer a browser's password prompt.

If you want a second lock on the dashboard specifically, put the basic auth on the
dashboard's routes only, and leave `/v1`, `/webhooks` and `/socket` alone.

## When it does not come up

Work down the layers; each of these has a distinct symptom:

* **`ERR_NAME_NOT_RESOLVED`**: DNS, or a typo in the domain. Nothing reached your server.
* **404 from the proxy**: the request arrived and no route matched. The `Host` in your
  proxy config is not the one being requested (or, in Swarm, the labels are not under
  `deploy.labels`).
* **A self-signed or default certificate**: the proxy has no route for that host either,
  so it never requested one. Same cause as the 404, seen from the TLS layer.
* **403 with a lock page**: Pepe is answering. No dashboard password is set.
* **400 "Host not allowed"**: Pepe is answering and `allowed_hosts` does not include the
  domain you are using.
* **The login page, on every deploy**: `SECRET_KEY_BASE` is unset.

`docker logs` on the container tells you which of these you are in within a line or two:
if Pepe logged `Access PepeWeb.Endpoint at ...`, the application is fine and the problem
is in front of it.
