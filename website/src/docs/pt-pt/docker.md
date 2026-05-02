---
title: Docker
description: Execute o Pepe em contentor e instale, dentro dele, as ferramentas de que o agente precisa.
---

Cada release publica uma imagem de contentor a par dos binários, em `amd64` e `arm64`. O
`docker pull` seleciona a arquitetura correta automaticamente, quer esteja num Mac
M-series, quer num servidor.

```bash
docker run -d --name pepe \
  -p 4000:4000 \
  -v pepe-data:/data \
  -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=uma-palavra-passe-forte \
  ghcr.io/pepe-agent/pepe
```

Abra <http://localhost:4000>, autentique-se e conclua a configuração no painel.

## Requisitos

Duas definições são obrigatórias. Omitir qualquer uma delas falha em silêncio.

### Volumes

São dois, e guardam coisas de natureza diferente.

O `/data` (o `PEPE_HOME`) é **estado**: configuração, agentes, conversas, workspaces e
Mnesia. É este o volume de que faz cópia de segurança. Sem ele, o `docker rm` apaga a
instalação inteira.

O `/tools` é **cache**: tudo aquilo que o agente instala para si próprio. Está no `PATH` e
é também onde fica a diretoria home do agente, em `/tools/home`. É este segundo pormenor
que faz com que "instalar uma vez" seja mesmo uma vez só, e tem uma secção própria mais
abaixo.

O `/tools` fica fora do `/data` de propósito. Uma cópia de segurança deve levar estado, não
dezenas de megabytes de binários e ficheiros de modelo que podem voltar a ser
descarregados, e esses ficheiros são específicos de arquitetura: um `/data` guardado numa
máquina arm64 e restaurado numa amd64 colocaria no `PATH` executáveis que ali não
funcionam.

```bash
-v pepe-data:/data -v pepe-tools:/tools
```

### Palavra-passe do painel

Um contentor não é loopback. O Pepe classifica-o como rede pública e, sem palavra-passe,
responde 403 a todos os pedidos. O painel não arranca.

```bash
-e PEPE_DASHBOARD_PASSWORD=...
```

Esta é uma política deliberada, não uma limitação do Docker. O Pepe recusa-se a expor um
painel sem autenticação numa rede pela qual não pode responder. A regra veio de um
incidente real: um serviço exposto, sem autenticação, foi varrido e abusado.

## Segredos

Não coloque chaves de API na imagem nem no ficheiro de configuração. Guarde apenas a
referência na configuração e forneça o valor real na execução. O Pepe resolve a referência
no momento da leitura e nunca grava o valor expandido.

```bash
# a configuração guarda apenas:  "api_key": "${OPENROUTER_API_KEY}"
docker run -d ... -e OPENROUTER_API_KEY=sk-... ghcr.io/pepe-agent/pepe
```

## Ferramentas para o agente

O agente é executado como utilizador sem privilégios e não pode executar `apt install`.
Isto é intencional: os comandos que executa são escolhidos por um modelo de linguagem, e
conceder root a esse processo não é uma decisão que nos caiba tomar por si.

A restrição custa menos do que parece, porque o root não é a chave que falta:

> Tudo o que o `apt` instala morre com o contentor. O apt escreve em `/usr` e `/etc`, que
> pertencem à camada gravável do contentor, não a um volume. O root dá permissão, não
> persistência: o que foi instalado desaparece no `docker rm` mesmo quando está a executar
> como root.

A pergunta nunca é como obter root. É onde a ferramenta tem de morar para sobreviver. Há
duas respostas, e hoje a primeira já resolve a maior parte dos casos sozinha.

### Tudo o que o agente instala para si próprio persiste

O `HOME` do agente é `/tools/home`, ou seja, fica dentro do volume `/tools`. É aqui que
está o truque todo. Os instaladores não perguntam onde está o seu volume: escrevem em
`~/.local/bin` e em `~/.cache`, e mais nada. Com o `HOME` na camada do contentor, tudo o
que o agente instala para si é descarregado de novo no contentor seguinte. Com o `HOME` no
volume, instala uma única vez.

A diferença é fácil de medir. O agente que transcreve uma mensagem de voz instala o `uv` e
descarrega um modelo Whisper, cerca de 75 MB. À primeira vez, demora 27 segundos. Num
contentor acabado de criar, a mesma transcrição demora 1,2 segundos, porque a cache
sobreviveu.

Assim, o `uv`, um `pip install --user`, um modelo Whisper, um toolchain de linguagem ou um
simples descarregamento:

```bash
curl -sL <url> -o /tools/op && chmod +x /tools/op
```

sobrevivem ao `docker rm` e a uma atualização do Pepe, sem root e sem reconstruir imagem
nenhuma. O `/tools` está no `PATH`, pelo que um executável ali colocado fica logo
disponível na shell do agente. O CLI do 1Password (`op`), o `gh`, o `kubectl` e o
`terraform` são todos um único ficheiro e não precisam de mais do que isto.

### Os pacotes de sistema ficam na imagem

Algumas ferramentas são pacotes de sistema a sério. O `psql`, o `imagemagick` e afins
espalham ficheiros e bibliotecas partilhadas por todo o sistema de ficheiros, e um volume
não comporta isso. Têm de fazer parte de uma imagem.

Um build arg instala pacotes adicionais sem que tenha de escrever um Dockerfile:

```bash
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick" .
```

Se prefere manter um Dockerfile seu, derivar da nossa imagem funciona igualmente bem e
continua a ser uma opção perfeitamente válida:

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

Os dois caminhos têm o mesmo custo: a cada nova release do Pepe, reconstrói a imagem.

#### Porque é que o `ffmpeg` não está na imagem

O `ffmpeg` parece o pacote de sistema óbvio para esta imagem, já que o Telegram envia voz
em OGG/Opus e o transcript tem de vir de algum lado. Nenhuma das duas rotas que de facto
transcrevem precisa dele. A API de transcrição aceita o ficheiro `.ogg` tal como ele chega,
sem conversão nenhuma, e o `faster-whisper` descodifica através do PyAV, que transporta os
próprios codecs dentro do wheel. Isto foi medido, não suposto: um ficheiro OGG/Opus foi
transcrito num Debian limpo, sem qualquer `ffmpeg` instalado. Só o CLI do `whisper.cpp`
invoca o `ffmpeg` por fora, e essa rota é opt-in.

Incluí-lo mesmo assim saía caro demais. O `ffmpeg` do Debian arrasta 204 pacotes e 121 MB
de ficheiros (LLVM, Mesa, um sintetizador de fala, um provador de teoremas), tudo para
servir uma pilha de aceleração de vídeo por GPU em que um contentor headless nunca toca.
Removê-lo baixou a imagem de 945 MB para 408 MB, cerca de 84 MB comprimidos, que é o que
descarrega de facto por arquitetura.

Se quiser mesmo o `ffmpeg`, seja para o CLI do `whisper.cpp` ou para outra coisa qualquer,
instale-o com o build arg acima ou coloque um build estático de ficheiro único em `/tools`,
que está no `PATH` e vive num volume.

### Testar uma ferramenta

```bash
docker exec -u root pepe apt-get update
docker exec -u root pepe apt-get install -y jq
```

Funciona, e é descartado no `docker rm` seguinte. Use para confirmar que a ferramenta
resolve o seu problema e só depois decida onde ela mora: no home do próprio agente, se ele
a consegue instalar sozinho, ou na imagem, se for pacote de sistema.

Arrancar o contentor como root (`docker run --user root`) é opt-in e nunca o comportamento
por omissão. Vale a pena repetir que não compra nada durável: o que o `apt` escreve
continua a morrer com o contentor, pelo que volta às duas respostas acima.

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

## Atualização

```bash
docker pull ghcr.io/pepe-agent/pepe
docker rm -f pepe
docker run -d ... ghcr.io/pepe-agent/pepe   # mesmos volumes, mesmas flags
```

Configuração, agentes e conversas voltam com o `/data`. As ferramentas do agente, o home
dele e todas as caches que lá estão voltam com o `/tools`, pelo que não reinstala nada na
primeira mensagem. Os pacotes instalados com `apt` não voltam, e é para esses que a imagem
existe.

## Acesso ao nó

```bash
docker exec -it pepe bin/pepe remote
```

Abre uma shell IEx ligada à release em execução, para inspecionar o sistema por dentro.
