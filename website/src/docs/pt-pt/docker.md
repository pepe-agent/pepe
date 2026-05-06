---
title: Docker
description: Corre o Pepe em contentor e instala, lá dentro, as ferramentas de que o agente precisa.
---

Cada versão publica uma imagem de contentor a par dos binários, para `amd64` e `arm64`. O
`docker pull` escolhe a arquitetura certa sozinho, quer estejas num Mac M-series, quer num
servidor.

```bash
docker run -d --name pepe \
  -p 4000:4000 \
  -v pepe-data:/data \
  -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=uma-palavra-passe-forte \
  ghcr.io/pepe-agent/pepe
```

Abre <http://localhost:4000>, inicia sessão e termina a configuração a partir do painel.

## Requisitos

Há duas definições obrigatórias, e deixar qualquer uma delas de fora falha em silêncio.

### Volumes

São dois, e guardam coisas de natureza diferente.

O `/data` (o `PEPE_HOME`) guarda **estado**: configuração, agentes, conversas, workspaces e
Mnesia. É deste volume que fazes cópia de segurança. Sem ele, o `docker rm` apaga a
instalação inteira.

O `/tools` é **cache**: tudo aquilo que o agente instala para si próprio. Está no `PATH` e é
também onde fica a pasta pessoal do agente, em `/tools/home`. É este segundo pormenor que
faz com que "instalar uma vez" seja mesmo uma vez só, e tem uma secção própria mais abaixo.

O `/tools` fica de propósito fora do `/data`. Uma cópia de segurança deve levar estado, e
não dezenas de megabytes de binários e ficheiros de modelo que se voltam a descarregar.
Além disso, esses ficheiros dependem da arquitetura: um `/data` guardado numa máquina arm64
e reposto numa amd64 iria colocar no `PATH` executáveis que ali não correm.

```bash
-v pepe-data:/data -v pepe-tools:/tools
```

### Palavra-passe do painel

Um contentor não é loopback. O Pepe classifica-o como rede pública e, sem palavra-passe,
devolve 403 a todos os pedidos: o painel não chega a servir.

```bash
-e PEPE_DASHBOARD_PASSWORD=...
```

Isto é uma política deliberada, não uma limitação do Docker. O Pepe recusa-se a expor um
painel sem autenticação numa rede pela qual não pode responder. A regra nasceu de um
incidente real, em que um serviço exposto e sem autenticação foi varrido e abusado.

## Segredos

Não metas chaves de API na imagem nem no ficheiro de configuração. Guarda só a referência
na configuração e fornece o valor verdadeiro no momento da execução. O Pepe resolve a
referência quando lê e nunca grava o valor expandido.

```bash
# a configuração guarda apenas:  "api_key": "${OPENROUTER_API_KEY}"
docker run -d ... -e OPENROUTER_API_KEY=sk-... ghcr.io/pepe-agent/pepe
```

## Instalar ferramentas para o agente

O agente corre como utilizador sem privilégios e não consegue executar `apt install`. Isto é
intencional: os comandos que ele executa são escolhidos por um modelo de linguagem, e dar
root a esse processo não é uma decisão a tomar em teu nome.

A restrição custa menos do que parece, porque o root não é a peça que falta:

> Tudo o que o `apt` instala morre com o contentor. O apt escreve em `/usr` e `/etc`, que
> pertencem à camada gravável do contentor e não a um volume. O root dá permissão, não
> persistência: o que for instalado desaparece no `docker rm` mesmo que corras como root.

A pergunta nunca é como chegar a root. É onde a ferramenta tem de morar para sobreviver. Há
duas respostas, e hoje a primeira já cobre a maior parte dos casos sozinha.

### Tudo o que o agente instala para si próprio persiste

O `HOME` do agente é `/tools/home`, ou seja, fica dentro do volume `/tools`. É aqui que está
o truque todo. Os instaladores não perguntam onde está o teu volume: escrevem em
`~/.local/bin` e em `~/.cache`, e mais nada. Com o `HOME` na camada do contentor, tudo o que
o agente prepara para si volta a ser descarregado no contentor seguinte. Com o `HOME` no
volume, instala uma única vez.

A diferença é fácil de medir. Um agente que transcreve uma mensagem de voz instala o `uv` e
puxa um modelo Whisper, cerca de 75 MB. À primeira, demora 27 segundos. Num contentor
acabado de criar, a mesma transcrição demora 1,2 segundos, porque a cache sobreviveu.

Assim, o `uv`, um `pip install --user`, um modelo Whisper, um toolchain de linguagem ou um
simples descarregamento:

```bash
curl -sL <url> -o /tools/op && chmod +x /tools/op
```

sobrevivem todos ao `docker rm` e a uma atualização do Pepe, sem root e sem reconstruir nada.
O `/tools` está no `PATH`, pelo que um binário ali deixado fica logo ao alcance da shell do
agente. O CLI do 1Password (`op`), o `gh`, o `kubectl` e o `terraform` são todos ficheiros
únicos e não precisam de mais do que isto.

### Os pacotes de sistema ficam na imagem

Algumas ferramentas são mesmo pacotes de sistema. O `psql`, o `imagemagick` e afins espalham
ficheiros e bibliotecas partilhadas por todo o sistema de ficheiros, e um volume não dá conta
disso. Têm de fazer parte de uma imagem.

Um build argument instala pacotes adicionais sem que precises sequer de escrever um
Dockerfile:

```bash
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick" .
```

Se preferires manter um Dockerfile teu, derivar da nossa imagem funciona igualmente bem e
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

Os dois caminhos têm o mesmo custo: a cada nova versão do Pepe, reconstróis a imagem.

#### Porque é que o `ffmpeg` não está na imagem

O `ffmpeg` parece o pacote de sistema óbvio para esta imagem, já que o Telegram envia voz em
OGG/Opus e a transcrição tem de vir de algum lado. Nenhuma das duas vias que de facto
transcrevem precisa dele. Uma API de transcrição aceita o `.ogg` tal como ele chega, sem
conversão nenhuma, e o `faster-whisper` descodifica através do PyAV, que traz os próprios
codecs dentro do wheel. Isto foi medido, não suposto: um ficheiro OGG/Opus transcrito num
Debian limpo, sem `ffmpeg` instalado em lado nenhum. Só o CLI do `whisper.cpp` chama o
`ffmpeg` por fora, e essa via é opt-in.

Incluí-lo mesmo assim custava muito mais do que valia. O pacote `ffmpeg` do Debian arrasta
204 pacotes e 121 MB de ficheiros (LLVM, Mesa, um sintetizador de fala, um provador de
teoremas), tudo para servir uma pilha de aceleração de vídeo por GPU em que um contentor
headless nunca toca. Deixá-lo cair baixou a imagem de 945 MB para 408 MB, cerca de 84 MB
comprimidos, que é o que descarregas de facto por arquitetura.

Se quiseres mesmo o `ffmpeg`, seja para o CLI do `whisper.cpp` seja para outra coisa
qualquer, instala-o com o build argument acima, ou deixa em `/tools` um build estático de
ficheiro único, que está no `PATH` e vive num volume.

### Experimentar uma ferramenta

```bash
docker exec -u root pepe apt-get update
docker exec -u root pepe apt-get install -y jq
```

Isto funciona, e é descartado no `docker rm` seguinte. Usa-o para confirmar que a ferramenta
resolve o teu problema e só depois decide onde ela mora: na pasta pessoal do próprio agente,
se ele a conseguir instalar sozinho, ou na imagem, se for pacote de sistema.

Arrancar o contentor como root (`docker run --user root`) é opt-in e nunca a predefinição.
Vale a pena repetir que não compra nada durável: o que o `apt` escreve continua a morrer com
o contentor, pelo que acabas de volta às duas respostas acima.

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

## Atualizar

```bash
docker pull ghcr.io/pepe-agent/pepe
docker rm -f pepe
docker run -d ... ghcr.io/pepe-agent/pepe   # mesmos volumes, mesmas flags
```

Configuração, agentes e conversas voltam com o `/data`. As ferramentas do agente, a pasta
pessoal dele e todas as caches que lá estão voltam com o `/tools`, pelo que não reinstala
nada na primeira mensagem. Os pacotes instalados com `apt` não voltam, e é para esses que a
imagem existe.

## Uma shell no nó

```bash
docker exec -it pepe bin/pepe remote
```

Abre uma shell IEx ligada à versão em execução, para inspecionares o sistema por dentro.
