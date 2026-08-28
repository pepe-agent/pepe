---
title: Publicar num servidor
description: Como pôr o Pepe num servidor próprio, com domínio e HTTPS, usando Docker Compose, Docker Swarm ou Kamal.
---

O [Docker](/pt-pt/docs/docker/) trata do contentor em si. Esta página trata do passo
seguinte: pô-lo numa máquina que outras pessoas conseguem alcançar, com um domínio e um
certificado à frente.

Seja qual for a ferramenta escolhida, o contentor é sempre o mesmo, e os dois volumes
também. O que muda é tudo à volta, e essas mudanças não são óbvias porque, localmente,
são todas valores predefinidos em que nunca precisaste de pensar.

## Quatro coisas que mudam assim que sais do localhost

**A palavra-passe do painel passa a ser obrigatória.** Já era assim no Docker, e a razão
é a mesma aqui: para o Pepe, só contam como privados os pedidos vindos da própria máquina
(loopback); tudo o resto é rede pública, e sem palavra-passe cada um desses pedidos é
recusado com um 403. Atrás de um proxy inverso, isso passa a ser *todos* os pedidos.

**O `PHX_HOST` é o nome público.** É a partir dele que o Pepe constrói os URLs absolutos:
os embeds do widget e os URLs de webhook que entregas ao Telegram ou ao WhatsApp. Sem o
definir, fica `localhost`, e esses URLs ficam silenciosamente errados enquanto tudo o
resto continua a funcionar normalmente.

**O `SECRET_KEY_BASE`, ou toda a gente perde a sessão a cada publicação.** Sem ele
definido, o Pepe gera um valor aleatório em cada arranque, o que resulta bem para um
contentor avulso mas é errado para um servidor: depois de cada deploy já ninguém tem a
sessão reconhecida, porque os cookies foram assinados pelo segredo antigo, e toda a gente
tem de voltar a entrar. Gera-o uma vez (`openssl rand -base64 48`) e guarda-o.

**Duas definições só existem dentro do `config.json`.** Não têm variável de ambiente
correspondente, por isso aplicam-se depois do primeiro arranque, em vez de serem passadas
logo na subida. O dispatch da própria CLI `pepe` dentro do contentor só funciona no
binário Burrito, não nesta versão simples, e por isso o caminho é passar por
`bin/pepe rpc`, chamando `dispatch_attached/1` (seguro mesmo com um nó que já está a
servir, ver [Docker](/pt-pt/docs/docker/#uma-shell-dentro-do-nó)):

```bash
docker exec -it <contentor> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "hosts", "agents.example.com"])'
docker exec -it <contentor> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "trusted-proxies", "10.0.1.0/24"])'
```

O `allowed_hosts` define os domínios a que o Pepe deve responder. Com a palavra-passe
definida mas sem essa lista, o Pepe aceita qualquer cabeçalho `Host`, porque é a
palavra-passe que faz de tranca e ele não tem forma de saber a que domínio te referias;
indicar o teu fecha um ataque chamado DNS rebinding, em que uma página maliciosa engana o
browser para este alcançar o teu Pepe sob outro nome. Já o `trusted_proxies` é aquele que
costuma ficar por definir e depois é mal diagnosticado: vazio, todo o cabeçalho
`X-Forwarded-For` é ignorado, o limitador de tentativas de login deixa de conseguir
distinguir visitantes, vê o endereço do proxy repetido para toda a gente, e a internet
inteira acaba a partilhar um único balde. Usa a rede onde o teu proxy está mesmo, nunca
`0.0.0.0/0`. Confiar em qualquer cabeçalho de encaminhamento equivale, na prática, a não
ter limitador nenhum.

<div class="note"><strong>Uma réplica. Sempre.</strong> Dos dois stores que o Pepe mantém nesse volume, o verdadeiro risco não é bem o estado neles guardado. É que uma segunda instância corre um segundo scheduler, e cada cron, watch e compromisso passa a disparar a dobrar (a <a href="#o-único-valor-predefinido-que-vale-a-pena-mudar">secção do Kamal</a> desenvolve isto, e vale para todas as ferramentas aqui referidas). Dois contentores em dois volumes são piores de um jeito mais discreto ainda: dois Pepes diferentes, cada um convencido de que é o único. Todos os exemplos abaixo fixam uma única réplica e, sempre que o comportamento predefinido do orquestrador é arrancar o contentor novo antes de parar o antigo, essa opção também é desligada.</div>

## Docker Compose, atrás do Caddy

A forma mais simples de ter isto a funcionar numa única máquina. O Caddy trata do
certificado sozinho, sem precisares de configurar nada além do nome do domínio.

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
      PEPE_DASHBOARD_PASSWORD: ${PEPE_DASHBOARD_PASSWORD:?defina isto no .env}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:?defina isto no .env}
      PHX_HOST: agents.example.com
      TZ: Europe/Lisbon
    # Sem `ports:`. Só o Caddy fica publicado; o Pepe só é alcançável pela rede interna,
    # em mais lado nenhum, por isso ninguém contorna o TLS batendo diretamente na
    # porta :4000 do host.
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

E é isto o proxy inverso todo. O Caddy pede o certificado logo no primeiro pedido e
renova-o sozinho depois; é em `caddy-data` que os guarda, por isso não apagues esse
volume de ânimo leve, ou vais ter de pedir tudo de novo e podes esbarrar no limite de
emissão do Let's Encrypt.

## Docker Swarm, atrás do Traefik

Se já corres um Swarm com Traefik, o Pepe junta-se a ele como qualquer outro serviço.
Duas coisas diferem de uma stack normal, e ambas têm a ver com o estado guardado nesse
volume.

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
      # A BEAM mais as migrações no arranque. Um healthcheck que começa a sondar cedo
      # demais mete a tarefa num ciclo de reinícios com cara de crash.
      start_period: 90s
    deploy:
      replicas: 1
      update_config:
        # Por predefinição, o Swarm arranca a tarefa nova antes de parar a antiga, o que
        # deixaria dois Pepes a usar o mesmo volume durante toda a publicação.
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

No Swarm, as labels do Traefik ficam sob `deploy.labels`, não sob o `labels:` normal do
serviço. Se ficarem no sítio errado, o Traefik simplesmente nunca chega a ver o serviço:
nenhum erro, só um 404 para esse host.

```bash
export PEPE_DASHBOARD_PASSWORD='...' SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker stack deploy -c pepe-stack.yml pepe
```

## Kamal

O Kamal publica o Pepe como se fosse a própria aplicação. Não há nada para compilar, por
isso o Dockerfile tem uma única linha; ele existe só para o Kamal ter algo para construir
e enviar para o teu próprio registry, e é também ali que entram pacotes de sistema, caso
o agente venha a precisar de algum:

```dockerfile
# Dockerfile
FROM ghcr.io/pepe-agent/pepe:0.10.2
```

Fixa sempre uma versão, nunca `latest`. O Kamal reconstrói a cada publicação, e usar
`latest` significaria que uma publicação de uma alteração tua, sem nada a ver com isto,
traria silenciosamente um Pepe novo junto.

```yaml
# config/deploy.yml
service: pepe
image: o-teu-utilizador/pepe

servers:
  web:
    # Um único host. Ver a nota abaixo.
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
kamal deploy    # depois disso
```

O proxy do Kamal termina o TLS e obtém o certificado a partir de `proxy.host`.

### O único valor predefinido que vale a pena mudar

Por desenho, o Kamal publica sem downtime: arranca o contentor novo, espera que ele
responda ao healthcheck, só depois muda o tráfego para lá e finalmente para o antigo.
Para uma aplicação cuja base de dados vive noutro sítio qualquer, isto é exatamente o
comportamento certo.

Durante esses poucos segundos há dois Pepes de pé ao mesmo tempo. O novo ainda não está a
servir nada, o que parece inofensivo, e para os pedidos até é: o proxy ainda não trocou.
Só que um scheduler não espera que lhe peçam nada.

**Crons, watches e compromissos disparam nos dois ao mesmo tempo.** Cada instância
arranca o seu próprio scheduler ao iniciar, a verificar de 30 em 30 segundos contra o
mesmo `config.json`, e o mecanismo que impede um job de correr duas vezes é apenas estado
em memória, dentro desse processo. Um segundo processo tem o seu próprio estado, vazio.
Por isso, tudo o que vencer durante essa janela corre duas vezes: dois turnos de agente
cobrados, duas mensagens entregues. O próprio supervisor do Pepe avisa disto, entre
parênteses: *corre uma única superfície de longa duração de cada vez, porque dois
schedulers sobre a mesma configuração disparam a dobrar.*

Os stores nesse volume são, já agora, menos dramáticos do que parecem. O SQLite abre em
modo WAL com um tempo limite de ocupação e, muito provavelmente, aguenta bem a situação.
O store Mnesia pode ser reposto pela instância que o encontrar impossível de carregar,
mas é a camada descartável por natureza: contexto de sessão com TTL e chaves de
deduplicação, por isso perdes o fio de conversas em aberto, nunca nada que tenhas
configurado de propósito. E o `config.json` só perde uma escrita se a instância antiga
estiver a fazer uma nesse instante exato, o que exige tráfego que está prestes a deixar
de receber.

**Se isto importa ou não depende do que corres.** Duas perguntas, e se a resposta for não
às duas, mantém a publicação sem downtime e ignora esta secção: há alguma coisa a disparar
por horário (crons, watches, compromissos), e há um gateway de Telegram configurado? O
Telegram é o caso que não depende de sorte nenhuma: as duas instâncias fazem polling
sobre o mesmo token de bot, uma delas recebe um `409`, e uma mensagem pode acabar
apanhada precisamente pela instância que está prestes a ser parada. Isto acontece em
todas as publicações, não só nalgumas.

Se alguma das duas se aplicar ao teu caso, para a aplicação primeiro e aceita a pequena
janela de indisponibilidade:

```bash
kamal app stop
kamal deploy
```

Se nem essa janela for aceitável, corre o Pepe como um **accessory** do Kamal.
`kamal accessory reboot pepe` pára o contentor antigo antes de arrancar o novo, sem
sobreposição nenhuma, e um accessory nunca entra em balanceamento de carga. É também a
forma natural de fazer isto quando o Pepe corre *ao lado* de uma aplicação que já publicas
com o Kamal, em vez de ser ele próprio a publicação principal.

## Verificações de saúde

O `/healthz` (ou `/health`) responde 200 assim que a aplicação está de pé, e fica
deliberadamente isento do redirecionamento para HTTPS, para que um proxy consiga
alcançá-lo por HTTP simples na rede interna.

Dá-lhe um período inicial generoso. O Pepe corre as suas migrações no arranque, e uma
verificação que começa a sondar já aos 10 segundos, num host mais carregado, acaba por
matar um contentor que estava mesmo prestes a ficar bem.

## Não ponhas HTTP basic auth à frente disto

É um instinto natural para um serviço com domínio próprio, e parte três coisas de uma
vez só. O painel já tem a sua própria palavra-passe, com página de login e limitador de
tentativas, por isso o basic auth não acrescenta nada ali; mas ele também acaba por cair
em cima do `/v1`, dos endpoints de webhook para onde o Telegram e o WhatsApp fazem POST,
e do WebSocket do widget de chat. Os três já têm credenciais próprias, e nenhum deles
sabe responder ao pedido de palavra-passe que um browser mostra.

Se quiseres mesmo uma segunda tranca só no painel, põe o basic auth apenas nas rotas
dele, e deixa `/v1`, `/webhooks` e `/socket` completamente em paz.

## Quando não sobe

Vai descendo pelas camadas; cada uma tem um sintoma bem distinto:

* **`ERR_NAME_NOT_RESOLVED`**: é DNS, ou um erro de escrita no domínio. Nada chegou sequer
  ao teu servidor.
* **404 vindo do proxy**: o pedido chegou, mas nenhuma rota correspondeu. O `Host`
  configurado no proxy não é o que está a ser pedido (ou, no Swarm, as labels não estão
  sob `deploy.labels`).
* **Um certificado autoassinado ou o certificado predefinido**: o proxy também não tem
  rota para esse host, por isso nunca chegou a pedir um certificado. É a mesma causa do
  404, só que vista do lado do TLS.
* **403 com uma página de cadeado**: o Pepe está a responder. Falta definir a
  palavra-passe do painel.
* **400 "Host not allowed"**: o Pepe está a responder, mas o `allowed_hosts` não inclui o
  domínio que estás a usar.
* **O ecrã de login, a cada publicação nova**: o `SECRET_KEY_BASE` não está definido.

O `docker logs` do contentor diz-te em uma ou duas linhas em qual destes casos estás: se
o Pepe registou `Access PepeWeb.Endpoint at ...`, a aplicação está bem, e o problema está
algures à frente dela.
