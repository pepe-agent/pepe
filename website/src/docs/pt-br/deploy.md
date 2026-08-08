---
title: Publicando em um servidor
description: Coloque o Pepe em um servidor próprio, com nome de domínio e HTTPS, usando Docker Compose, Docker Swarm ou Kamal.
---

O [Docker](/pt-br/docs/docker/) cobre o container em si. Esta página cobre o passo
seguinte: colocá-lo em uma máquina que outras pessoas alcançam, com domínio e
certificado.

Seja qual for a ferramenta, o container é o mesmo e os dois volumes também. O que muda é
tudo em volta, e o que muda não é óbvio, porque localmente são todos padrões que você
nunca precisou pensar a respeito.

## Quatro coisas que mudam assim que ele sai do localhost

**A senha do dashboard passa a ser obrigatória.** Já era no Docker, e a razão é a mesma
aqui: para o Pepe, só requisições vindas da própria máquina contam como privadas
(loopback); todo o resto é rede pública, e sem senha cada requisição dessas é recusada
com 403. Atrás de um proxy reverso, isso é *toda* requisição.

**O `PHX_HOST` é o nome público.** O Pepe monta URLs absolutas a partir dele: os embeds do
widget e as URLs de webhook que você entrega ao Telegram ou ao WhatsApp. Sem definir, ele
é `localhost`, e essas URLs ficam silenciosamente erradas enquanto todo o resto funciona.

**O `SECRET_KEY_BASE`, ou todo mundo é deslogado a cada deploy.** Sem ele, o Pepe gera um
aleatório a cada boot, o que serve para um container avulso e é errado para um servidor:
depois de cada deploy o login de ninguém é mais reconhecido (os cookies de sessão foram
assinados com o segredo antigo), e todo mundo entra de novo. Gere uma vez
(`openssl rand -base64 48`) e guarde.

**Dois ajustes existem só no `config.json`.** Eles não têm variável de ambiente, então são
aplicados depois do primeiro boot, e não passados na subida. O dispatch de CLI do próprio
`pepe` do container só roda no binário Burrito, não nesse release puro, então o caminho é
`bin/pepe rpc`, chamando `dispatch_attached/1` (seguro contra um nó que já está servindo -
ver [Docker](/pt-br/docs/docker/#uma-shell-no-no)):

```bash
docker exec -it <container> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "hosts", "agents.example.com"])'
docker exec -it <container> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "trusted-proxies", "10.0.1.0/24"])'
```

O `allowed_hosts` diz ao Pepe a quais domínios ele deve responder. Com senha configurada
e sem allowlist, o Pepe aceita qualquer `Host`, porque a senha é a tranca e ele não tem
como saber qual domínio você quis dizer; nomear o seu fecha um ataque chamado DNS
rebinding, em que uma página maliciosa engana o navegador para alcançar o seu Pepe sob
outro nome. O `trusted_proxies` é o que as pessoas pulam e depois diagnosticam errado:
vazio, todo `X-Forwarded-For` é ignorado, então o limitador de tentativas de login não
consegue distinguir os visitantes, vê o endereço do proxy para todo mundo e a internet
inteira divide um balde só. Use a rede em que o seu proxy realmente está, não
`0.0.0.0/0`. Confiar em qualquer cabeçalho de encaminhamento é o mesmo que não ter
limitador nenhum.

<div class="note"><strong>Uma réplica. Sempre.</strong> Dos dois stores que o Pepe mantém nesse volume, o risco não é bem o estado guardado nele. É que uma segunda instância roda um segundo scheduler, e todo cron, watch e compromisso dispara em dobro (a <a href="#o-único-padrão-a-mudar">seção do Kamal</a> destrincha isso, e vale para todas as ferramentas daqui). Dois containers em dois volumes são piores de um jeito mais silencioso: dois Pepes diferentes, cada um convencido de que é o único. Todos os exemplos abaixo fixam uma réplica, e onde o padrão do orquestrador é subir o novo container antes de derrubar o velho, isso também é desligado.</div>

## Docker Compose, atrás do Caddy

A menor coisa que funciona em uma máquina só. O Caddy tira o certificado sozinho, sem
configuração além do nome do domínio.

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
      TZ: America/Sao_Paulo
    # Sem `ports:`. Só o Caddy é publicado; o Pepe é alcançável na rede interna e em
    # lugar nenhum além dela, então ninguém contorna o TLS batendo no host na :4000.
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

Esse é o proxy reverso inteiro. O Caddy pede o certificado na primeira requisição e
renova sozinho; o `caddy-data` é onde ele os guarda, então não apague esse volume por
descuido ou você vai pedir tudo de novo e pode bater no limite de emissão do Let's
Encrypt.

## Docker Swarm, atrás do Traefik

Se você já roda um Swarm com Traefik, o Pepe entra nele como qualquer outro serviço. Duas
coisas diferem de uma stack normal, e as duas são por causa do estado naquele volume.

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
      TZ: America/Sao_Paulo
    networks:
      - network_public
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:4000/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      # A BEAM mais as migrations no boot. Um healthcheck que dispara cedo demais põe a
      # task num loop de restart com cara de crash.
      start_period: 90s
    deploy:
      replicas: 1
      update_config:
        # O padrão do Swarm sobe a task nova antes de derrubar a velha, o que colocaria
        # dois Pepes em um volume durante todo o deploy.
        order: stop-first
        failure_action: rollback
      rollback_config:
        order: stop-first
      placement:
        # Volumes locais não seguem a task para outro nó.
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

No Swarm os labels do Traefik ficam sob `deploy.labels`, não sob o `labels:` do próprio
serviço. No lugar errado, o Traefik simplesmente nunca enxerga o serviço: nenhum erro,
só um 404 para aquele host.

```bash
export PEPE_DASHBOARD_PASSWORD='...' SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker stack deploy -c pepe-stack.yml pepe
```

## Kamal

O Kamal publica o Pepe como a aplicação. Não há nada para compilar, então o Dockerfile tem
uma linha. Ele existe para o Kamal ter o que construir e enviar ao seu próprio registry, e
é também onde entram pacotes de sistema, se o agente vier a precisar de algum:

```dockerfile
# Dockerfile
FROM ghcr.io/pepe-agent/pepe:0.10.2
```

Fixe uma versão em vez de `latest`. O Kamal reconstrói a cada deploy, e `latest`
significaria que um deploy de uma mudança sua sem relação nenhuma traz um Pepe novo junto,
caladamente.

```yaml
# config/deploy.yml
service: pepe
image: seu-usuario/pepe

servers:
  web:
    # Um host só. Veja a observação abaixo.
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
    TZ: America/Sao_Paulo
  secret:
    - PEPE_DASHBOARD_PASSWORD
    - SECRET_KEY_BASE

volumes:
  - /opt/pepe/data:/data
  - /opt/pepe/tools:/tools
```

```bash
kamal setup     # na primeira vez
kamal deploy    # depois disso
```

O proxy do Kamal termina o TLS e tira o certificado a partir do `proxy.host`.

### O único padrão a mudar

O Kamal publica sem downtime por design: ele sobe o container novo, espera ele responder
ao healthcheck, move o tráfego para lá e só então derruba o antigo. Para uma aplicação
cujo banco vive em outro lugar, isso está exatamente certo.

Nesses poucos segundos existem dois Pepes de pé ao mesmo tempo. O novo ainda não está
atendendo nada, o que soa inofensivo, e para requisições é: o proxy ainda não trocou. Mas um
scheduler não espera ser chamado.

**Crons, watches e compromissos disparam nos dois.** Cada instância sobe o próprio scheduler
no boot, ticando a cada 30 segundos contra o mesmo `config.json`, e o claim que impede um job
de rodar duas vezes é estado em memória dentro daquele processo. Um segundo processo tem o
dele, vazio. Então tudo que vencer na janela roda duas vezes: dois turnos de agente cobrados,
duas mensagens entregues. O próprio supervisor do Pepe diz isso, num parêntese: *rode uma
única superfície de longa duração por vez, dois schedulers em uma config disparam em dobro.*

Os stores no volume são menos dramáticos do que parecem, para registro. O SQLite é aberto em
WAL com busy timeout e muito provavelmente aguentaria. O store Mnesia pode ser resetado pela
instância que o encontrar sem carregar, mas ele é a camada descartável por design: contexto
de sessão sob TTL e chaves de dedupe, então perde-se o fio das conversas abertas, não algo
que você configurou. E o `config.json` só perde uma escrita se a instância antiga estiver
fazendo uma naquele exato instante, o que exige tráfego que ela está prestes a parar de
receber.

**Se isso importa depende do que você roda.** Duas perguntas, e se as duas respostas forem
não, mantenha o deploy sem downtime e ignore esta seção: existe algo que dispara por horário
(crons, watches, compromissos), e existe um gateway do Telegram configurado? O Telegram é o
que não depende de sorte: as duas instâncias fazem polling no mesmo token de bot, uma leva
`409`, e uma mensagem pode ser pega justamente pela instância que está prestes a ser
derrubada. Isso acontece em todo deploy, não em alguns.

Se qualquer um dos dois se aplica, pare a aplicação antes e aceite a janela curta:

```bash
kamal app stop
kamal deploy
```

Se a janela não for aceitável, rode o Pepe como **accessory** do Kamal. O `kamal accessory
reboot pepe` derruba o container antigo antes de subir o novo, sem sobreposição, e um
accessory nunca entra em balanceamento. Esse também é o formato natural quando o Pepe vai
*ao lado* de uma aplicação que você já publica com o Kamal, em vez de ser ele o deploy.

## Healthchecks

O `/healthz` (ou `/health`) responde 200 assim que a aplicação sobe, e é deliberadamente
isento do redirecionamento para HTTPS, para um proxy conseguir alcançá-lo por HTTP
interno simples.

Dê um período inicial generoso. O Pepe roda as migrations no boot, e um check que começa
a sondar depois de 10 segundos em um host carregado vai matar um container que estava
prestes a ficar de pé.

## Não coloque HTTP basic auth na frente

É um instinto natural para um serviço em um domínio, e quebra três coisas de uma vez. O
dashboard já tem senha própria, com página de login e limitador de tentativas, então o
basic auth não acrescenta nada ali, mas também cai em cima do `/v1`, dos endpoints de
webhook para onde o Telegram e o WhatsApp fazem POST, e do WebSocket do widget de chat.
Os três carregam credencial própria e nenhum deles sabe responder a um prompt de senha
do navegador.

Se quiser uma segunda tranca no dashboard especificamente, coloque o basic auth apenas
nas rotas dele, e deixe `/v1`, `/webhooks` e `/socket` em paz.

## Quando não sobe

Vá descendo as camadas; cada uma delas tem um sintoma distinto:

* **`ERR_NAME_NOT_RESOLVED`**: DNS, ou um erro de digitação no domínio. Nada chegou ao seu
  servidor.
* **404 vindo do proxy**: a requisição chegou e nenhuma rota casou. O `Host` na config do
  proxy não é o que está sendo pedido (ou, no Swarm, os labels não estão sob
  `deploy.labels`).
* **Certificado autoassinado ou padrão**: o proxy também não tem rota para aquele host,
  então nunca pediu um certificado. Mesma causa do 404, vista da camada de TLS.
* **403 com uma página de cadeado**: o Pepe está respondendo. Falta a senha do dashboard.
* **400 "Host not allowed"**: o Pepe está respondendo e o `allowed_hosts` não inclui o
  domínio que você está usando.
* **A tela de login, a cada deploy**: o `SECRET_KEY_BASE` não está definido.

O `docker logs` no container diz em uma ou duas linhas em qual desses casos você está: se
o Pepe registrou `Access PepeWeb.Endpoint at ...`, a aplicação está bem e o problema está
na frente dela.
