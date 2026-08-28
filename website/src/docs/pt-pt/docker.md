---
title: Docker
description: Corre o Pepe dentro de um contentor e instala lá dentro as ferramentas de que o agente precisar.
---

Cada versão publicada vem com uma imagem de contentor a par dos binários,
para `amd64` e para `arm64`. O `docker pull` escolhe a arquitetura certa
sozinho, quer estejas num Mac com chip M-series, quer num servidor qualquer.

```bash
docker run -d --name pepe \
  -p 4000:4000 \
  -v pepe-data:/data \
  -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=uma-palavra-passe-forte \
  ghcr.io/pepe-agent/pepe
```

Abre <http://localhost:4000>, inicia sessão, e termina a configuração
diretamente no painel.

## Requisitos

Duas definições são obrigatórias, e esquecer qualquer uma delas falha em
silêncio, sem avisar.

### Volumes

São dois volumes, e cada um guarda um tipo de coisa diferente.

O `/data` (o `PEPE_HOME`) guarda o **estado**: configuração, agentes,
conversas, workspaces e a Mnesia. É deste volume que deves fazer cópia de
segurança; sem ele, um `docker rm` leva a instalação inteira com ele.

Já o `/tools` é **cache**: tudo o que o agente instala por conta própria.
Está no `PATH`, e é também onde mora a pasta pessoal do agente, em
`/tools/home`. É este segundo pormenor que faz "instalar uma vez" ser
mesmo só uma vez, e por isso tem uma secção só dele, mais abaixo.

O `/tools` fica de propósito fora do `/data`. Uma cópia de segurança devia
levar só estado, não dezenas de megabytes de binários e de ficheiros de
modelo que se podem voltar a descarregar sem custo. E há mais: esses
ficheiros dependem da arquitetura, por isso um `/data` guardado numa
máquina arm64 e restaurado numa amd64 acabaria por colocar no `PATH`
executáveis que ali simplesmente não correm.

```bash
-v pepe-data:/data -v pepe-tools:/tools
```

### Palavra-passe do painel

Um contentor não conta como sendo a tua própria máquina: o Pepe trata a
rede dele como pública e, sem palavra-passe, recusa todos os pedidos com
um HTTP 403. O painel nem chega a abrir.

```bash
-e PEPE_DASHBOARD_PASSWORD=...
```

Isto é uma política deliberada, não uma limitação do Docker. O Pepe
recusa-se a expor um painel sem autenticação numa rede pela qual não pode
responder. A regra nasceu de um incidente real, em que um serviço exposto
sem autenticação foi varrido e explorado por terceiros.

## Segredos

Nunca metas chaves de API dentro da imagem nem no ficheiro de configuração.
Guarda ali só a referência, e fornece o valor verdadeiro no momento em que
o contentor arranca. O Pepe resolve essa referência quando lê a
configuração, e nunca grava o valor já expandido.

```bash
# a configuração guarda apenas:  "api_key": "${OPENROUTER_API_KEY}"
docker run -d ... -e OPENROUTER_API_KEY=sk-... ghcr.io/pepe-agent/pepe
```

## Instalar ferramentas para o agente

O agente corre como um utilizador sem privilégios e não consegue executar
`apt install`. Isto é intencional: quem escolhe os comandos que ele executa
é um modelo de linguagem, e dar-lhe acesso de root não é uma decisão para
tomar em teu nome.

Esta restrição custa bem menos do que parece à primeira vista, porque o
root nunca foi a peça que faltava:

> Tudo o que o `apt` instala morre junto com o contentor. O apt escreve em
> `/usr` e em `/etc`, pastas que pertencem à camada gravável do contentor,
> não a um volume. O root dá permissão, não persistência: o que instalares
> desaparece no `docker rm`, mesmo que estejas a correr como root.

A pergunta certa nunca é como chegar a root, é onde é que uma ferramenta
tem de viver para sobreviver. Há duas respostas para isso, e hoje em dia a
primeira já resolve a maior parte dos casos sozinha.

### Tudo o que o agente instala para si mesmo fica lá

O `HOME` do agente é `/tools/home`, ou seja, cai dentro do volume `/tools`.
É aqui que está o truque todo: os instaladores não perguntam onde fica o
teu volume, escrevem sempre em `~/.local/bin` e em `~/.cache`, e mais lado
nenhum. Com o `HOME` na camada do contentor, tudo o que o agente prepara
para si é descarregado outra vez no contentor seguinte. Com o `HOME` no
volume, instala-se uma única vez e fica.

A diferença mede-se facilmente. Um agente que precisa de transcrever uma
mensagem de voz instala o `uv` e puxa um modelo Whisper, à volta de 75 MB.
A primeira vez demora 27 segundos. Num contentor acabadinho de criar, a
mesma transcrição já demora só 1,2 segundos, porque a cache sobreviveu à
troca.

Assim, o `uv`, um `pip install --user`, um modelo Whisper, um toolchain de
alguma linguagem, ou um simples download:

```bash
curl -sL <url> -o /tools/op && chmod +x /tools/op
```

sobrevivem todos ao `docker rm` e a uma atualização do Pepe, sem precisar
de root e sem reconstruir nada. O `/tools` está no `PATH`, por isso um
binário largado ali fica logo ao alcance da shell do agente. O CLI do
1Password (`op`), o `gh`, o `kubectl` e o `terraform` são todos ficheiros
únicos, e não pedem mais do que isto.

### Os pacotes de sistema ficam na imagem

Há ferramentas que são mesmo pacotes de sistema. O `psql`, o `imagemagick`
e afins espalham ficheiros e bibliotecas partilhadas por todo o sistema de
ficheiros, e um simples volume não dá conta disso. Essas têm de fazer
parte de uma imagem.

Um build argument já instala pacotes extra, sem sequer precisares de
escrever um Dockerfile:

```bash
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick" .
```

Se preferires manter o teu próprio Dockerfile, derivar da nossa imagem
funciona igualmente bem, e continua a ser uma opção perfeitamente válida:

```dockerfile
FROM ghcr.io/pepe-agent/pepe
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client \
  && rm -rf /var/lib/apt/lists/*
USER pepe
```

```bash
docker build -t o-meu-pepe .
docker run -d -p 4000:4000 -v pepe-data:/data -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=... o-meu-pepe
```

Qualquer um dos dois caminhos vem com o mesmo custo: a cada nova versão do
Pepe, tens de reconstruir a imagem.

#### Porque é que o `ffmpeg` não vem na imagem

O `ffmpeg` até parece o pacote de sistema óbvio para esta imagem, já que o
Telegram manda a voz em OGG/Opus e uma transcrição tem de vir de algum
lado. Só que nenhuma das duas vias que de facto transcrevem precisa dele.
Uma API de transcrição aceita o `.ogg` exatamente como chega, sem qualquer
conversão, e o `faster-whisper` descodifica através do PyAV, que já traz
os próprios codecs dentro do wheel. Isto foi medido, não suposto: um
ficheiro OGG/Opus foi transcrito com sucesso num Debian limpo, sem
`ffmpeg` instalado em lado nenhum. Só o CLI do `whisper.cpp` é que chama o
`ffmpeg` por fora, e essa via é opcional.

Trazê-lo na mesma custava muito mais do que valia a pena. O pacote
`ffmpeg` do Debian arrasta consigo 204 pacotes e 121 MB de ficheiros (LLVM,
Mesa, um sintetizador de fala, um provador de teoremas), tudo isto só para
servir uma pilha de aceleração de vídeo por GPU que um contentor headless
nunca vai sequer tocar. Tirá-lo de lá baixou a imagem de 945 MB para 408
MB, cerca de 84 MB comprimidos, que é o que de facto se descarrega por
arquitetura.

Se quiseres mesmo o `ffmpeg`, seja para o CLI do `whisper.cpp` seja para
outra coisa qualquer, instala-o com o build argument acima, ou deixa em
`/tools` um build estático de ficheiro único, que fica no `PATH` e vive
num volume.

### Experimentar uma ferramenta antes de decidir

```bash
docker exec -u root pepe apt-get update
docker exec -u root pepe apt-get install -y jq
```

Isto funciona, e é descartado no próximo `docker rm`. Serve para
confirmares que a ferramenta resolve mesmo o teu problema, e só depois é
que decides onde ela deve morar: na pasta pessoal do próprio agente, se
ele conseguir instalá-la sozinho, ou na imagem, se for um pacote de
sistema.

Arrancar o contentor como root (`docker run --user root`) é opcional e
nunca a predefinição. Vale a pena repetir que isso não compra nada de
durável: o que o `apt` escreve continua a morrer junto com o contentor,
por isso acabas sempre a voltar às duas respostas de cima.

## Compose

O Pepe já vem com um `docker-compose.yml` pronto, não há nada para
escreveres de raiz:

```bash
curl -O https://raw.githubusercontent.com/pepe-agent/pepe/master/docker-compose.yml
```

É o mesmo `docker run` de cima, só que com os dois volumes e a
palavra-passe já no lugar:

```yaml
services:
  pepe:
    image: ghcr.io/pepe-agent/pepe:latest
    restart: unless-stopped
    ports:
      - "4000:4000"
    volumes:
      - pepe-data:/data # estado: configuração, agentes, conversas. É deste que fazes backup.
      - pepe-tools:/tools # a pasta pessoal do agente e tudo o que ele instala para si.
    environment:
      # O `:?` é propositado: sem palavra-passe, o painel responderia 403 a todos os
      # pedidos (um contentor não é loopback), pelo que o compose recusa arrancar em vez
      # de te entregar um contentor que corre e não serve nada.
      PEPE_DASHBOARD_PASSWORD: ${PEPE_DASHBOARD_PASSWORD:?set this in a .env file}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY}
      TZ: UTC

volumes:
  pepe-data:
  pepe-tools:
```

Os segredos ficam num ficheiro `.env` ao lado, nunca no ficheiro do
compose e nunca dentro da imagem. A configuração do Pepe refere-se a eles
pelo nome (`"api_key": "${OPENROUTER_API_KEY}"`) e resolve-os no momento
da leitura, de modo que o valor real só chega a existir dentro do
ambiente:

```bash
# .env
PEPE_DASHBOARD_PASSWORD=uma-palavra-passe-forte
OPENROUTER_API_KEY=sk-...
```

Cada segredo precisa das duas metades: o valor no `.env`, **e** uma linha
em `environment:` a dar-lhe nome. O Compose lê o `.env` só para preencher
os `${...}` dentro do próprio ficheiro compose, não para meter valores
diretamente no contentor. Assim, uma chave que exista apenas no `.env`
nunca chega ao Pepe, e o que recebes é um "no model configured" sem
qualquer pista do porquê. Acrescenta uma linha para cada segredo que
usares.

A partir dessa pasta:

```bash
docker compose up -d
docker compose logs -f          # segue o registo em direto
docker compose exec pepe bin/pepe remote   # abre uma shell IEx no nó em execução
```

## Colocar num servidor

Tudo o que foi dito até aqui corre numa única máquina, acessível em
`localhost`. Atrás de um domínio, com TLS e um proxy inverso, entram em
jogo mais quatro pormenores, e nenhum deles depende do Docker. Vê
[Publicar num servidor](/pt-pt/docs/deploy/) para veres Compose atrás do
Caddy, Docker Swarm atrás do Traefik, e Kamal.

## Atualizar

Com o Compose:

```bash
docker compose pull
docker compose up -d
```

Sem ele:

```bash
docker pull ghcr.io/pepe-agent/pepe
docker rm -f pepe
docker run -d ... ghcr.io/pepe-agent/pepe   # mesmos volumes, mesmas flags
```

A configuração, os agentes e as conversas voltam com o `/data`. As
ferramentas do agente, a pasta pessoal dele e tudo o que lá tinha em cache
voltam com o `/tools`, por isso nada é reinstalado logo na primeira
mensagem. Já os pacotes instalados com `apt` não voltam, e é justamente
para esses que a imagem existe.

Vale a pena reter uma coisa: o `docker compose down` para os contentores e
deixa os volumes intactos, que é o que se quer. O `docker compose down -v`
apaga também os volumes, e com eles a instalação inteira.

## Uma shell dentro do nó

```bash
docker exec -it pepe bin/pepe remote            # ou: docker compose exec pepe bin/pepe remote
```

Abre uma shell IEx ligada à versão em execução, para inspecionares o
sistema por dentro.

Para um único comando `pepe`, sem precisares de uma shell completa, usa
`bin/pepe rpc` com `dispatch_attached/1`: são os mesmos comandos que o
`pepe` corre em qualquer outro sítio, só que já preparados para serem
seguros contra um nó que já está a servir:

```bash
docker exec pepe bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["agent", "list"])'
```

O `bin/pepe <comando>` sozinho não funciona aqui: o contentor é uma versão
pura, e o dispatch de CLI dela só se ativa no binário Burrito, distribuído
à parte. `bin/pepe rpc`/`remote` é sempre o caminho de entrada, seja como
for. O `dispatch_attached/1` existe porque vários comandos (`plugin
install`, `eval`, `doctor`, `cron`, entre outros, não só `run`/`chat`/
`tui`) alteram definições globais pensadas para serem decididas uma única
vez, no arranque. Isso é inofensivo num processo de CLI recém-iniciado que
já vai terminar logo a seguir, mas já não é inofensivo num nó que já está
de pé e vai continuar assim.
