---
title: Docker
description: Rode o Pepe em container e instale, dentro dele, as ferramentas que o agente precisa.
---

Toda release publica uma imagem de container junto dos binários, em `amd64` e `arm64`. O
`docker pull` seleciona a arquitetura correta automaticamente, seja num Mac M-series ou
num servidor.

```bash
docker run -d --name pepe \
  -p 4000:4000 \
  -v pepe-data:/data \
  -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=uma-senha-forte \
  ghcr.io/pepe-agent/pepe
```

Abra <http://localhost:4000>, entre com a senha e conclua a configuração pelo painel.

## Requisitos

Duas definições são obrigatórias. Omitir qualquer uma delas falha em silêncio.

### Volumes

São dois, e guardam coisas de natureza diferente.

O `/data` (o `PEPE_HOME`) é **estado**: configuração, agentes, conversas, workspaces e
Mnesia. É esse o volume que você faz backup. Sem ele, o `docker rm` apaga a instalação
inteira.

O `/tools` é **cache**: tudo que o agente instala para si mesmo. Ele está no `PATH` e é
também onde fica o diretório home do agente, em `/tools/home`. Esse segundo detalhe é o
que faz o "instalou uma vez, ficou instalado" valer de verdade, e tem uma seção própria
mais abaixo.

O `/tools` fica fora do `/data` de propósito. Um backup deve carregar estado, não dezenas
de megabytes de binários e arquivos de modelo que podem ser baixados de novo, e esses
arquivos são específicos de arquitetura: um `/data` salvo numa máquina arm64 e restaurado
numa amd64 colocaria no `PATH` executáveis que não rodam ali.

```bash
-v pepe-data:/data -v pepe-tools:/tools
```

### Senha do painel

Um container não é loopback. O Pepe o classifica como rede pública e, sem senha, responde
403 a todas as requisições. O painel não sobe.

```bash
-e PEPE_DASHBOARD_PASSWORD=...
```

Essa é uma política deliberada, não uma limitação do Docker. O Pepe se recusa a expor um
painel sem autenticação numa rede pela qual não pode responder. A regra veio de um
incidente real: um serviço exposto, sem autenticação, foi varrido e abusado.

## Segredos

Não coloque chaves de API na imagem nem no arquivo de configuração. Guarde apenas a
referência na configuração e forneça o valor real na execução. O Pepe resolve a referência
no momento da leitura e nunca grava o valor expandido.

```bash
# a configuração guarda apenas:  "api_key": "${OPENROUTER_API_KEY}"
docker run -d ... -e OPENROUTER_API_KEY=sk-... ghcr.io/pepe-agent/pepe
```

## Ferramentas para o agente

O agente roda como usuário sem privilégios e não pode executar `apt install`. Isso é
intencional: os comandos que ele executa são escolhidos por um modelo de linguagem, e
conceder root a esse processo não é uma decisão que caiba a nós tomar por você.

A restrição custa menos do que parece, porque root não é a chave que falta:

> Tudo que o `apt` instala morre junto com o container. O apt grava em `/usr` e `/etc`,
> que pertencem à camada gravável do container, não a um volume. Root dá permissão, não
> persistência: o que foi instalado some no `docker rm` mesmo rodando como root.

A pergunta nunca é como virar root. É onde a ferramenta precisa morar para sobreviver. Há
duas respostas, e a primeira hoje já resolve a maior parte dos casos sozinha.

### Tudo que o agente instala para si mesmo persiste

O `HOME` do agente é `/tools/home`, ou seja, fica dentro do volume `/tools`. É aí que está
o truque inteiro. Instaladores não perguntam onde está o seu volume: eles escrevem em
`~/.local/bin` e `~/.cache`, e em nenhum outro lugar. Com o `HOME` na camada do container,
tudo que o agente instala para si é baixado de novo no próximo container. Com o `HOME` no
volume, ele instala uma vez.

A diferença é fácil de medir. O agente que transcreve uma mensagem de voz instala o `uv` e
baixa um modelo Whisper, uns 75 MB. Na primeira vez, leva 27 segundos. Num container novo
em folha, a mesma transcrição leva 1,2 segundo, porque o cache sobreviveu.

Então o `uv`, um `pip install --user`, um modelo Whisper, um toolchain de linguagem ou um
download simples:

```bash
curl -sL <url> -o /tools/op && chmod +x /tools/op
```

sobrevivem ao `docker rm` e a uma atualização do Pepe, sem root e sem reconstruir imagem
nenhuma. O `/tools` está no `PATH`, então um executável solto ali já pode ser chamado
direto do shell do agente. O CLI do 1Password (`op`), o `gh`, o `kubectl` e o `terraform`
são todos um único arquivo e não precisam de mais nada além disso.

### Pacotes de sistema ficam na imagem

Algumas ferramentas são pacotes de sistema de verdade. O `psql`, o `imagemagick` e afins
espalham arquivos e bibliotecas compartilhadas por todo o sistema de arquivos, e um volume
não dá conta disso. Eles precisam fazer parte de uma imagem.

Um build arg instala pacotes extras sem que você precise escrever um Dockerfile:

```bash
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick" .
```

Se você prefere manter um Dockerfile seu, derivar da nossa imagem funciona igualmente bem
e continua sendo uma opção perfeitamente válida:

```dockerfile
FROM ghcr.io/pepe-agent/pepe
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client \
  && rm -rf /var/lib/apt/lists/*
USER pepe
```

```bash
docker build -t meu-pepe .
docker run -d -p 4000:4000 -v pepe-data:/data -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=... meu-pepe
```

Os dois caminhos têm o mesmo custo: a cada nova release do Pepe, você reconstrói a imagem.

#### Por que o `ffmpeg` não está na imagem

O `ffmpeg` parece o pacote de sistema óbvio para esta imagem, já que o Telegram manda voz
em OGG/Opus e a transcrição precisa sair de algum lugar. Nenhuma das duas rotas que de fato
transcrevem precisa dele. A API de transcrição aceita o arquivo `.ogg` exatamente como ele
chega, sem conversão nenhuma, e o `faster-whisper` decodifica através do PyAV, que carrega
os próprios codecs dentro do wheel. Isso foi medido, não suposto: um arquivo OGG/Opus foi
transcrito num Debian limpo, sem nenhum `ffmpeg` instalado. Só o CLI do `whisper.cpp` chama
o `ffmpeg` por fora, e essa rota é opt-in.

Mandar o pacote assim mesmo custava caro demais. O `ffmpeg` do Debian arrasta 204 pacotes e
121 MB de arquivos (LLVM, Mesa, um sintetizador de fala, um provador de teoremas), tudo
para servir uma pilha de aceleração de vídeo por GPU em que um container headless nunca
encosta. Removê-lo levou a imagem de 945 MB para 408 MB, uns 84 MB comprimidos, que é o
que você de fato baixa por arquitetura.

Se você quiser o `ffmpeg` mesmo assim, seja para o CLI do `whisper.cpp` ou para qualquer
outra coisa, instale com o build arg acima ou coloque um build estático de arquivo único em
`/tools`, que está no `PATH` e fica num volume.

### Testando uma ferramenta

```bash
docker exec -u root pepe apt-get update
docker exec -u root pepe apt-get install -y jq
```

Funciona, e é descartado no próximo `docker rm`. Use para confirmar que a ferramenta
resolve o seu problema e, aí sim, decida onde ela mora: no home do próprio agente, se ele
consegue instalar sozinho, ou na imagem, se for pacote de sistema.

Subir o container como root (`docker run --user root`) é opt-in e nunca o padrão. Vale
repetir que isso não traz nenhum ganho duradouro: o que o `apt` grava continua morrendo com o
container, e você volta às duas respostas acima.

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
dele e todos os caches que estão lá dentro voltam com o `/tools`, então ele não reinstala
nada na primeira mensagem. Pacotes instalados com `apt` não voltam, e é para eles que a
imagem existe.

## Acesso ao nó

```bash
docker exec -it pepe bin/pepe remote
```

Abre um shell IEx conectado ao release em execução, para inspecionar o sistema por dentro.
