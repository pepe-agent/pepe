---
title: Publicar num servidor
description: Coloque o Pepe num servidor com domínio e TLS, usando Docker Compose, Docker Swarm ou Kamal.
---

O [Docker](/pt-pt/docs/docker/) cobre o contentor em si. Esta página cobre o passo
seguinte: colocá-lo numa máquina que outras pessoas alcançam, com domínio e certificado.

Seja qual for a ferramenta, o contentor é o mesmo e os dois volumes também. O que muda é
tudo à volta, e o que muda não é óbvio, porque localmente são todos valores por omissão
em que nunca teve de pensar.

## Quatro coisas que mudam assim que sai do localhost

**A palavra-passe do painel passa a ser obrigatória.** Já era no Docker, e a razão é a
mesma aqui: o Pepe trata tudo o que não é loopback como rede pública e devolve 403 a todos
os pedidos sem ela. Atrás de um proxy inverso, isso é *todos* os pedidos.

**O `PHX_HOST` é o nome público.** O Pepe constrói URLs absolutos a partir dele: os embeds
do widget e os URLs de webhook que entrega ao Telegram ou ao WhatsApp. Por definir, fica
`localhost`, e esses URLs ficam silenciosamente errados enquanto tudo o resto funciona.

**O `SECRET_KEY_BASE`, ou toda a gente perde a sessão a cada publicação.** Sem ele, o Pepe
gera um aleatório a cada arranque, o que serve para um contentor avulso e está errado para
um servidor: os cookies de sessão assinados com o segredo antigo deixam de validar. Gere
uma vez (`openssl rand -base64 48`) e guarde.

**Duas definições existem apenas no `config.json`.** Não têm variável de ambiente, por
isso são aplicadas depois do primeiro arranque, e não passadas na subida:

```bash
docker exec -it <contentor> bin/pepe rpc '
  Pepe.Config.update(fn c ->
    c
    |> put_in(["dashboard", "allowed_hosts"], ["agents.example.com"])
    |> put_in(["dashboard", "trusted_proxies"], ["10.0.1.0/24"])
  end)'
```

O `allowed_hosts` fecha o DNS rebinding: com palavra-passe definida e sem lista de
permissões, o Pepe aceita qualquer `Host`, porque a palavra-passe é a tranca e ele não tem
como saber que domínio quis dizer. O `trusted_proxies` é o que se salta e depois se
diagnostica mal: sem ele, todo o `X-Forwarded-For` é ignorado, por isso o limitador de
tentativas de início de sessão vê o endereço do proxy para toda a gente e a internet
inteira partilha um único balde. Use a rede em que o seu proxy está mesmo, não
`0.0.0.0/0`. Confiar em qualquer cabeçalho de reencaminhamento é o mesmo que não ter
limitador nenhum.

<div class="note"><strong>Uma réplica. Sempre.</strong> Dos dois stores que o Pepe mantém nesse volume, o risco não é bem o estado nele guardado. É que uma segunda instância corre um segundo scheduler, e cada cron, watch e compromisso dispara a dobrar (a <a href="#o-único-valor-por-omissão-a-mudar">secção do Kamal</a> destrinça isto, e vale para todas as ferramentas aqui). Dois contentores em dois volumes são piores de um modo mais silencioso: dois Pepes diferentes, cada um convencido de que é o único. Todos os exemplos abaixo fixam uma réplica, e onde o comportamento por omissão do orquestrador é arrancar o contentor novo antes de parar o antigo, isso também é desligado.</div>

## Docker Compose, atrás do Caddy

A coisa mais pequena que funciona numa só máquina. O Caddy trata do certificado sozinho,
sem configuração para além do nome do domínio.

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
      PEPE_DASHBOARD_PASSWORD: ${PEPE_DASHBOARD_PASSWORD:?defina no .env}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:?defina no .env}
      PHX_HOST: agents.example.com
      TZ: Europe/Lisbon
    # Sem `ports:`. Só o Caddy é publicado; o Pepe é alcançável na rede interna e em mais
    # lado nenhum, por isso ninguém contorna o TLS batendo no host na :4000.
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

É este o proxy inverso inteiro. O Caddy pede o certificado no primeiro pedido e renova-o
sozinho; o `caddy-data` é onde os guarda, por isso não apague esse volume por descuido ou
vai voltar a pedi-los todos e pode bater no limite de emissão do Let's Encrypt.

## Docker Swarm, atrás do Traefik

Se já corre um Swarm com Traefik, o Pepe entra nele como qualquer outro serviço. Duas
coisas diferem de uma stack normal, e ambas são por causa do estado nesse volume.

```yaml
# pepe-stack.yml, publicado com: docker stack deploy -c pepe-stack.yml pepe
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
      TZ: Europe/Lisbon
    networks:
      - network_public
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:4000/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      # A BEAM mais as migrações no arranque. Um healthcheck que dispara cedo demais põe
      # a tarefa num ciclo de reinícios com ar de crash.
      start_period: 90s
    deploy:
      replicas: 1
      update_config:
        # O comportamento por omissão do Swarm arranca a tarefa nova antes de parar a
        # antiga, o que poria dois Pepes num volume durante toda a publicação.
        order: stop-first
        failure_action: rollback
      rollback_config:
        order: stop-first
      placement:
        # Volumes locais não seguem a tarefa para outro nó.
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

No Swarm, as labels do Traefik ficam sob `deploy.labels`, e não sob o `labels:` do próprio
serviço. No sítio errado, o Traefik simplesmente nunca vê o serviço: nenhum erro, apenas
um 404 para esse host.

```bash
export PEPE_DASHBOARD_PASSWORD='...' SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker stack deploy -c pepe-stack.yml pepe
```

## Kamal

O Kamal publica o Pepe como a aplicação. Não há nada para compilar, por isso o Dockerfile
tem uma linha. Existe para o Kamal ter o que construir e enviar para o seu próprio
registry, e é também onde entram pacotes de sistema, se o agente vier a precisar de algum:

```dockerfile
# Dockerfile
FROM ghcr.io/pepe-agent/pepe:0.10.2
```

Fixe uma versão em vez de `latest`. O Kamal reconstrói a cada publicação, e `latest`
significaria que uma publicação de uma alteração sua sem relação nenhuma traz um Pepe novo
com ela, em silêncio.

```yaml
# config/deploy.yml
service: pepe
image: o-seu-utilizador/pepe

servers:
  web:
    # Um só host. Veja a nota abaixo.
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
    TZ: Europe/Lisbon
  secret:
    - PEPE_DASHBOARD_PASSWORD
    - SECRET_KEY_BASE

volumes:
  - /opt/pepe/data:/data
  - /opt/pepe/tools:/tools
```

```bash
kamal setup     # da primeira vez
kamal deploy    # a partir daí
```

O proxy do Kamal termina o TLS e trata do certificado a partir do `proxy.host`.

### O único valor por omissão a mudar

O Kamal publica sem downtime por desenho: arranca o contentor novo, espera que responda ao
healthcheck, move o tráfego para lá e só então pára o antigo. Para uma aplicação cuja base
de dados vive noutro sítio, isso está exactamente certo.

Nesses poucos segundos existem dois Pepes de pé ao mesmo tempo. O novo ainda não está a
servir nada, o que soa inofensivo, e para pedidos é: o proxy ainda não trocou. Mas um
scheduler não espera que lhe peçam.

**Crons, watches e compromissos disparam nos dois.** Cada instância arranca o seu próprio
scheduler no boot, a ticar de 30 em 30 segundos contra o mesmo `config.json`, e o claim que
impede um job de correr duas vezes é estado em memória dentro desse processo. Um segundo
processo tem o seu, vazio. Por isso tudo o que vencer na janela corre duas vezes: dois turnos
de agente cobrados, duas mensagens entregues. O próprio supervisor do Pepe di-lo, num
parêntese: *corra uma única superfície de longa duração de cada vez, dois schedulers numa
config disparam a dobrar.*

Os stores no volume são menos dramáticos do que parecem, para registo. O SQLite é aberto em
WAL com busy timeout e muito provavelmente aguentava. O store Mnesia pode ser reposto pela
instância que o encontrar sem carregar, mas é a camada descartável por desenho: contexto de
sessão sob TTL e chaves de dedupe, por isso perde-se o fio das conversas abertas, não algo
que tenha configurado. E o `config.json` só perde uma escrita se a instância antiga estiver a
fazer uma nesse exacto instante, o que exige tráfego que está prestes a deixar de receber.

**Se isso importa depende do que corre.** Duas perguntas, e se ambas as respostas forem não,
mantenha a publicação sem downtime e ignore esta secção: há algo que dispara por horário
(crons, watches, compromissos), e há um gateway do Telegram configurado? O Telegram é o que
não depende de sorte: as duas instâncias fazem polling no mesmo token de bot, uma leva `409`,
e uma mensagem pode ser apanhada precisamente pela instância que está prestes a ser parada.
Isso acontece em todas as publicações, não em algumas.

Se qualquer um dos dois se aplicar, pare a aplicação antes e aceite a janela curta:

```bash
kamal app stop
kamal deploy
```

Se a janela não for aceitável, corra o Pepe como **accessory** do Kamal. O `kamal accessory
reboot pepe` pára o contentor antigo antes de arrancar o novo, sem sobreposição, e um
accessory nunca entra em balanceamento. Esse é também o formato natural quando o Pepe vai
*ao lado* de uma aplicação que já publica com o Kamal, em vez de ser ele a publicação.

## Healthchecks

O `/healthz` (ou `/health`) responde 200 assim que a aplicação está de pé, e está
deliberadamente isento do reencaminhamento para HTTPS, para um proxy o conseguir alcançar
por HTTP interno simples.

Dê um período inicial generoso. O Pepe corre as migrações no arranque, e um check que
começa a sondar ao fim de 10 segundos num host carregado mata um contentor que estava
prestes a ficar bem.

## Não ponha HTTP basic auth à frente

É um instinto natural para um serviço num domínio, e parte três coisas de uma vez. O
painel já tem palavra-passe própria, com página de início de sessão e limitador de
tentativas, por isso o basic auth não acrescenta nada aí, mas também fica por cima do
`/v1`, dos endpoints de webhook para onde o Telegram e o WhatsApp fazem POST, e do
WebSocket do widget de chat. Os três levam credencial própria e nenhum deles sabe
responder a um pedido de palavra-passe do navegador.

Se quiser uma segunda tranca no painel em concreto, ponha o basic auth apenas nas rotas
dele, e deixe `/v1`, `/webhooks` e `/socket` em paz.

## Quando não arranca

Vá descendo as camadas; cada uma tem um sintoma distinto:

* **`ERR_NAME_NOT_RESOLVED`**: DNS, ou uma gralha no domínio. Nada chegou ao seu servidor.
* **404 vindo do proxy**: o pedido chegou e nenhuma rota correspondeu. O `Host` na
  configuração do proxy não é o que está a ser pedido (ou, no Swarm, as labels não estão
  sob `deploy.labels`).
* **Certificado auto-assinado ou por omissão**: o proxy também não tem rota para esse
  host, por isso nunca pediu um certificado. Mesma causa do 404, vista da camada de TLS.
* **403 com uma página de cadeado**: o Pepe está a responder. Falta a palavra-passe do
  painel.
* **400 "Host not allowed"**: o Pepe está a responder e o `allowed_hosts` não inclui o
  domínio que está a usar.
* **O ecrã de início de sessão, a cada publicação**: o `SECRET_KEY_BASE` não está definido.

O `docker logs` no contentor diz numa ou duas linhas em qual destes casos está: se o Pepe
registou `Access PepeWeb.Endpoint at ...`, a aplicação está bem e o problema está à frente
dela.
