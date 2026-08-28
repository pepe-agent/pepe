---
title: Publicando em um servidor
description: Coloque o Pepe em um servidor próprio, com domínio e HTTPS, usando Docker Compose, Docker Swarm ou Kamal.
---

O [Docker](/pt-br/docs/docker/) cobre o container em si. Esta página cobre o passo
seguinte: colocar esse container numa máquina que outras pessoas conseguem alcançar, atrás
de um domínio e de um certificado.

Independente da ferramenta escolhida, o container continua o mesmo, e os dois volumes
também. O que muda é tudo ao redor, e essas mudanças não são óbvias justamente porque,
localmente, tudo isso são padrões nos quais você nunca precisou pensar.

## Quatro coisas que mudam assim que sai do localhost

**A senha do dashboard vira obrigatória.** Já era assim no Docker, e o motivo é o mesmo
aqui: para o Pepe, só uma requisição vinda da própria máquina conta como privada
(loopback); tudo o mais é rede pública, e sem senha, cada uma dessas requisições é
recusada com 403. Atrás de um proxy reverso, isso passa a valer para *toda* requisição.

**`PHX_HOST` define o nome público.** É a partir dele que o Pepe monta as URLs absolutas:
os embeds do widget e as URLs de webhook que você entrega ao Telegram ou ao WhatsApp. Sem
definir esse valor, ele assume `localhost`, e essas URLs ficam erradas silenciosamente
enquanto o resto continua funcionando normalmente.

**`SECRET_KEY_BASE`, ou todo mundo é deslogado a cada deploy.** Sem essa variável, o Pepe
gera um valor aleatório em cada boot, o que é inofensivo para um container avulso, mas
errado num servidor: depois de cada deploy, o login de ninguém é mais reconhecido (os
cookies de sessão foram assinados com o segredo anterior), e todo mundo precisa entrar de
novo. Gere esse valor uma única vez (`openssl rand -base64 48`) e guarde-o.

**Dois ajustes só existem dentro do `config.json`.** Eles não têm variável de ambiente
correspondente, então são aplicados depois do primeiro boot, e não passados na subida do
container. O dispatch de CLI do próprio `pepe`, dentro do container, só funciona no
binário Burrito, não nesse release puro, então o caminho aqui é `bin/pepe rpc`, chamando
`dispatch_attached/1` (seguro mesmo com um nó que já está servindo, veja
[Docker](/pt-br/docs/docker/#um-shell-dentro-do-nó)):

```bash
docker exec -it <container> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "hosts", "agents.example.com"])'
docker exec -it <container> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "trusted-proxies", "10.0.1.0/24"])'
```

O `allowed_hosts` informa ao Pepe a quais domínios ele deve responder. Com senha
configurada mas sem allowlist, o Pepe aceita qualquer `Host` recebido, já que a senha é a
tranca e ele não tem como adivinhar qual domínio você quis dizer; nomear o seu fecha um
ataque chamado DNS rebinding, em que uma página maliciosa engana o navegador para acessar
seu Pepe sob outro nome. Já o `trusted_proxies` é o ajuste que as pessoas costumam pular,
e depois diagnosticam errado: deixado vazio, todo `X-Forwarded-For` é ignorado, então o
limitador de tentativas de login não consegue distinguir um visitante do outro, enxerga só
o endereço do proxy repetido para todo mundo, e a internet inteira acaba dividindo um
único balde de tentativas. Use a faixa de rede onde o seu proxy realmente está, nunca
`0.0.0.0/0`: confiar em qualquer cabeçalho de encaminhamento equivale a não ter limitador
nenhum.

<div class="note"><strong>Uma réplica. Sempre.</strong> Dos dois stores que o Pepe mantém nesse volume, o risco de verdade não está tanto no estado guardado ali. Está em que uma segunda instância sobe um segundo scheduler, e aí todo cron, watch e compromisso dispara em dobro (a <a href="#o-único-padrão-que-vale-mudar">seção do Kamal</a> destrincha isso, e vale para todas as ferramentas descritas aqui). Dois containers em dois volumes são um problema ainda mais silencioso: dois Pepes diferentes, cada um convencido de que é o único rodando. Todos os exemplos abaixo fixam uma única réplica, e onde o padrão do orquestrador seria subir o container novo antes de derrubar o antigo, isso também é desligado.</div>

## Docker Compose, atrás do Caddy

É a configuração mais enxuta que já funciona numa máquina só. O Caddy resolve o
certificado sozinho, sem exigir nada além do nome do domínio.

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
    # Sem `ports:`. Só o Caddy fica publicado; o Pepe só é alcançável pela rede interna,
    # em nenhum outro lugar, então ninguém consegue contornar o TLS batendo direto na :4000.
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

E é isso, o proxy reverso inteiro está aí. O Caddy pede o certificado já na primeira
requisição e renova sozinho depois disso; é no volume `caddy-data` que ele os guarda, por
isso não vale apagar esse volume por descuido, senão você acaba pedindo tudo de novo e
pode esbarrar no limite de emissão do Let's Encrypt.

## Docker Swarm, atrás do Traefik

Quem já roda um Swarm com Traefik pode simplesmente adicionar o Pepe como mais um serviço.
Duas coisas fogem do padrão de uma stack comum, e as duas giram em torno do estado
guardado naquele volume.

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
      # A BEAM mais as migrations do boot. Um healthcheck cedo demais deixa a task presa
      # num loop de restart que parece um crash, mas não é.
      start_period: 90s
    deploy:
      replicas: 1
      update_config:
        # O padrão do Swarm sobe a task nova antes de derrubar a velha, o que deixaria
        # dois Pepes escrevendo no mesmo volume durante todo o deploy.
        order: stop-first
        failure_action: rollback
      rollback_config:
        order: stop-first
      placement:
        # Volumes locais não acompanham a task se ela migrar para outro nó.
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

No Swarm, os labels do Traefik vão sob `deploy.labels`, e não sob o `labels:` do próprio
serviço. Coloque no lugar errado e o Traefik simplesmente nunca vê o serviço: nenhum erro
aparece, só um 404 quando alguém tenta acessar aquele host.

```bash
export PEPE_DASHBOARD_PASSWORD='...' SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker stack deploy -c pepe-stack.yml pepe
```

## Kamal

O Kamal publica o Pepe como se fosse a própria aplicação. Não há nada para compilar, então
o Dockerfile fica numa linha só, e existe principalmente para o Kamal ter algo para
construir e enviar ao seu registry, além de ser o lugar certo para adicionar pacotes de
sistema, caso o agente venha a precisar de algum:

```dockerfile
# Dockerfile
FROM ghcr.io/pepe-agent/pepe:0.10.2
```

Fixe sempre uma versão, nunca use `latest`. O Kamal reconstrói a cada deploy, e com
`latest` até um deploy de uma mudança completamente sem relação acabaria trazendo junto um
Pepe novo, sem avisar.

```yaml
# config/deploy.yml
service: pepe
image: seu-usuario/pepe

servers:
  web:
    # Um único host. Veja a observação logo abaixo.
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
kamal deploy    # daí em diante
```

O proxy do Kamal encerra o TLS e obtém o certificado a partir de `proxy.host`.

### O único padrão que vale mudar

Por design, o Kamal publica sem downtime: sobe o container novo, espera ele responder ao
healthcheck, só então move o tráfego para lá e derruba o antigo. Para uma aplicação cujo
banco vive em outro lugar, esse comportamento é exatamente o correto.

Durante esses poucos segundos, porém, existem dois Pepes de pé ao mesmo tempo. O novo
ainda não está atendendo nada, o que parece inofensivo, e para requisições realmente é: o
proxy ainda não trocou o tráfego. O problema é que um scheduler não espera ser chamado
para agir.

**Crons, watches e compromissos disparam nos dois ao mesmo tempo.** Cada instância sobe o
próprio scheduler já no boot, verificando a cada 30 segundos contra o mesmo
`config.json`, e o controle que evita rodar o mesmo job duas vezes é só um estado em
memória, dentro daquele processo específico. Um segundo processo tem o seu próprio
estado, vazio. Então qualquer coisa que vença o prazo durante essa janela roda duas vezes:
dois turnos de agente cobrados, duas mensagens entregues. O próprio supervisor do Pepe
já avisa disso, entre parênteses: *rode uma única superfície de longa duração por vez,
dois schedulers apontando para a mesma config disparam tudo em dobro.*

Os stores desse volume, para constar, são menos dramáticos do que parecem à primeira
vista. O SQLite abre em modo WAL com busy timeout e, na prática, provavelmente aguentaria
a sobreposição. Já o store Mnesia pode simplesmente ser resetado pela instância que o
encontrar impossível de carregar, mas ele foi pensado como camada descartável desde o
início: guarda contexto de sessão com TTL e chaves de dedupe, então o que se perde é o fio
de conversas abertas, não nada que você tenha configurado. E o `config.json` só perde uma
escrita se a instância antiga estiver fazendo alguma exatamente naquele instante, o que
exigiria tráfego que ela já está prestes a parar de receber.

**Se isso importa ou não depende do que você roda.** Duas perguntas resolvem: existe algo
disparando por horário (crons, watches, compromissos), e existe um gateway do Telegram
configurado? Se as duas respostas forem não, pode manter o deploy sem downtime e ignorar
esta seção inteira. O Telegram é o caso que não depende de sorte nenhuma: as duas
instâncias fazem polling do mesmo token de bot, uma delas leva um `409`, e uma mensagem
pode acabar sendo capturada exatamente pela instância que está prestes a ser derrubada.
Isso acontece em todo deploy, não só ocasionalmente.

Se qualquer uma das duas se aplicar ao seu caso, pare a aplicação antes e aceite a janela
curta de indisponibilidade:

```bash
kamal app stop
kamal deploy
```

Quando nem essa janela é aceitável, rode o Pepe como **accessory** do Kamal. O comando
`kamal accessory reboot pepe` derruba o container antigo antes de subir o novo, sem
nenhuma sobreposição, e um accessory nunca entra em balanceamento de carga. Esse também é
o formato mais natural quando o Pepe roda *ao lado* de uma aplicação que você já publica
com o Kamal, em vez de ser ele mesmo o alvo do deploy.

## Healthchecks

O `/healthz` (ou `/health`) responde 200 assim que a aplicação sobe, e fica
deliberadamente isento do redirecionamento para HTTPS, para que um proxy consiga alcançá-lo
por HTTP simples, dentro da rede interna.

Dê um período inicial generoso a esse check. O Pepe roda as migrations no boot, e um check
que já começa a sondar depois de 10 segundos, num host carregado, acaba matando um
container que estava só prestes a ficar pronto.

## Não coloque HTTP basic auth na frente

É um instinto natural para qualquer serviço exposto num domínio, mas aqui quebra três
coisas de uma vez. O dashboard já tem senha própria, com página de login e limitador de
tentativas, então o basic auth não agrega nada ali; só que ele também acaba caindo em cima
do `/v1`, dos endpoints de webhook para onde o Telegram e o WhatsApp mandam POST, e do
WebSocket do widget de chat. Os três já carregam sua própria credencial, e nenhum deles
sabe responder a um prompt de senha do navegador.

Se ainda assim você quiser uma segunda tranca, específica para o dashboard, coloque o
basic auth só nas rotas dele, e deixe `/v1`, `/webhooks` e `/socket` de fora.

## Quando não sobe

Vá descendo camada por camada; cada uma delas tem um sintoma bem distinto:

* **`ERR_NAME_NOT_RESOLVED`**: problema de DNS, ou erro de digitação no domínio. Nada
  chegou a alcançar o seu servidor.
* **404 vindo do proxy**: a requisição chegou, mas nenhuma rota bateu com ela. O `Host`
  configurado no proxy não é o que está sendo pedido (ou, no Swarm, os labels não estão
  sob `deploy.labels`).
* **Certificado autoassinado ou padrão**: o proxy também não tem rota para aquele host,
  então nem chegou a pedir um certificado. É a mesma causa do 404 anterior, só que vista
  pela camada de TLS.
* **403 com uma página de cadeado**: o Pepe está respondendo normalmente. Falta apenas
  configurar a senha do dashboard.
* **400 "Host not allowed"**: o Pepe está respondendo, mas o `allowed_hosts` não inclui o
  domínio que você está usando.
* **Tela de login toda vez, a cada deploy**: o `SECRET_KEY_BASE` não foi definido.

O `docker logs` do container costuma revelar, em uma ou duas linhas, em qual desses
cenários você está: se o Pepe registrou `Access PepeWeb.Endpoint at ...`, a aplicação está
saudável e o problema está em alguma camada na frente dela.
