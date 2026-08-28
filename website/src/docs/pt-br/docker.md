---
title: Docker
description: Rode o Pepe como container e instale, ali dentro, as ferramentas que o agente precisar.
---

Toda release sai acompanhada de uma imagem de container, para `amd64` e `arm64`. Ao rodar `docker pull`, a arquitetura certa é escolhida sozinha, tanto faz se é um Mac M-series ou um servidor qualquer.

```bash
docker run -d --name pepe \
  -p 4000:4000 \
  -v pepe-data:/data \
  -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=uma-senha-forte \
  ghcr.io/pepe-agent/pepe
```

Depois é só abrir <http://localhost:4000>, entrar com a senha e terminar a configuração pelo painel.

## Requisitos

Duas configurações não são opcionais, e deixar de fazer qualquer uma delas quebra tudo sem avisar.

### Volumes

São dois volumes, e cada um guarda um tipo de coisa diferente.

O `/data` (o `PEPE_HOME`) guarda **estado**: configuração, agentes, conversas, workspaces e o Mnesia. É esse volume que entra no seu backup, porque sem ele um `docker rm` apaga a instalação inteira.

Já o `/tools` é **cache**: tudo que o próprio agente instala para si. Ele fica no `PATH` e também abriga o diretório home do agente, em `/tools/home`. Esse segundo ponto é o que garante que "instalei uma vez" realmente signifique isso, e vale uma seção só para ele, mais abaixo.

Manter o `/tools` fora do `/data` é proposital: um backup deveria carregar estado, não dezenas de megabytes de binários e modelos que dá para baixar de novo, ainda mais sendo arquivos específicos de arquitetura. Restaurar num amd64 um `/data` salvo num arm64 deixaria, no `PATH`, executáveis que simplesmente não rodam ali.

```bash
-v pepe-data:/data -v pepe-tools:/tools
```

### Senha do painel

Um container não é tratado como a sua própria máquina: o Pepe assume que a rede dele é pública e, sem senha configurada, recusa toda requisição com HTTP 403. O painel simplesmente não sobe.

```bash
-e PEPE_DASHBOARD_PASSWORD=...
```

Isso é uma política deliberada, não uma limitação do Docker. O Pepe se recusa a expor um painel sem autenticação numa rede que não pode garantir, e essa regra nasceu de um incidente real: um serviço exposto sem autenticação foi varrido e explorado.

## Segredos

Chave de API não vai nem na imagem, nem no arquivo de configuração. O que fica na configuração é só a referência; o valor de verdade é fornecido na hora de rodar o container. O Pepe resolve essa referência no momento da leitura e nunca chega a gravar o valor expandido.

```bash
# a configuração guarda só isto:  "api_key": "${OPENROUTER_API_KEY}"
docker run -d ... -e OPENROUTER_API_KEY=sk-... ghcr.io/pepe-agent/pepe
```

## Ferramentas para o agente

O agente roda sem privilégios e não consegue executar `apt install`. Isso é de propósito: quem escolhe os comandos que ele executa é um modelo de linguagem, e dar root para esse processo não é uma decisão que devêssemos tomar no seu lugar.

Essa restrição custa bem menos do que parece, porque root não é a peça que falta:

> Tudo que o `apt` instala morre junto com o container. O `apt` escreve em `/usr` e `/etc`, que pertencem à camada gravável do container, não a um volume. Root te dá permissão, não persistência: o que foi instalado some no próximo `docker rm`, root ou não.

A pergunta certa nunca é como virar root. É onde a ferramenta precisa morar para sobreviver a isso. Há duas respostas possíveis, e a primeira delas já resolve a maioria dos casos sozinha.

### O que o agente instala sozinho, persiste

O `HOME` do agente aponta para `/tools/home`, ou seja, mora dentro do volume `/tools`. É nisso que está o truque inteiro: um instalador não sai perguntando onde fica o seu volume, ele simplesmente escreve em `~/.local/bin`, em `~/.cache`, e é só. Com `HOME` na camada do container, tudo que o agente monta para si é baixado de novo a cada container novo. Com `HOME` dentro do volume, ele instala uma única vez.

Dá para medir a diferença. Um agente que transcreve uma mensagem de voz precisa instalar o `uv` e baixar um modelo Whisper, uns 75 MB. Na primeira vez isso leva 27 segundos. Num container recém-criado, a mesma transcrição leva 1,2 segundo, porque o cache já estava lá.

Então o `uv`, um `pip install --user`, um modelo Whisper, um toolchain de alguma linguagem, ou até um download qualquer:

```bash
curl -sL <url> -o /tools/op && chmod +x /tools/op
```

tudo isso sobrevive a um `docker rm` e a uma atualização do Pepe, sem precisar de root nem de reconstruir imagem nenhuma. Como o `/tools` já está no `PATH`, um binário solto ali pode ser chamado direto pelo shell do agente. O CLI do 1Password (`op`), o `gh`, o `kubectl` e o `terraform` são todos arquivo único e não pedem mais nada além disso.

### Pacote de sistema vai na imagem

Algumas ferramentas são mesmo pacotes de sistema. `psql`, `imagemagick` e companhia espalham arquivos e bibliotecas compartilhadas pelo sistema de arquivos inteiro, coisa que um volume não resolve. Essas precisam entrar na imagem.

Um build argument instala pacotes extras sem que você escreva um Dockerfile:

```bash
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick" .
```

Quem preferir manter o próprio Dockerfile também tem esse caminho, partindo da nossa imagem:

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

Os dois caminhos cobram o mesmo preço: cada release nova do Pepe pede uma imagem reconstruída.

#### Por que o `ffmpeg` fica de fora da imagem

Parece óbvio incluir o `ffmpeg` nessa imagem, já que o Telegram manda áudio em OGG/Opus e a transcrição tem que sair de algum lugar. Só que nenhuma das duas rotas que efetivamente transcrevem precisa dele. Uma API de transcrição recebe o `.ogg` do jeito que chega, sem converter nada, e o `faster-whisper` decodifica via PyAV, que já traz os próprios codecs dentro do wheel. Isso foi medido, não suposto: um OGG/Opus foi transcrito num Debian limpo, sem `ffmpeg` nenhum instalado. A única rota que de fato chama `ffmpeg` por fora é o CLI do `whisper.cpp`, e essa é opcional.

Incluir o pacote mesmo assim saía caro demais. O `ffmpeg` do Debian puxa 204 pacotes e 121 MB de arquivos (LLVM, Mesa, um sintetizador de fala, um provador de teoremas), tudo para sustentar uma pilha de aceleração de vídeo por GPU que um container headless jamais vai usar. Tirando ele, a imagem caiu de 945 MB para 408 MB, algo como 84 MB comprimidos, que é o que você realmente baixa por arquitetura.

Se ainda assim você quiser `ffmpeg`, seja para o CLI do `whisper.cpp` ou para outra coisa qualquer, dá para instalar com o build argument acima, ou colocar um binário estático de arquivo único em `/tools`, que já está no `PATH` e mora num volume.

### Testando uma ferramenta antes de decidir

```bash
docker exec -u root pepe apt-get update
docker exec -u root pepe apt-get install -y jq
```

Isso funciona e some no próximo `docker rm`. Use para confirmar que a ferramenta resolve o seu problema, e só depois decida onde ela vai morar de verdade: no home do próprio agente, se ele consegue instalar sozinho, ou na imagem, se for pacote de sistema.

Rodar o container como root (`docker run --user root`) é opcional e nunca vem como padrão. Vale repetir: isso não traz ganho nenhum que dure, porque o que o `apt` grava continua morrendo com o container, e você volta para as duas respostas de cima de qualquer jeito.

## Compose

O Pepe já traz um `docker-compose.yml` pronto, então não tem nada para escrever do zero:

```bash
curl -O https://raw.githubusercontent.com/pepe-agent/pepe/master/docker-compose.yml
```

É o mesmo `docker run` de cima, só que com os dois volumes e a senha já no lugar:

```yaml
services:
  pepe:
    image: ghcr.io/pepe-agent/pepe:latest
    restart: unless-stopped
    ports:
      - "4000:4000"
    volumes:
      - pepe-data:/data # estado: configuração, agentes, conversas. É deste que você faz backup.
      - pepe-tools:/tools # o home do agente e tudo que ele instala para si mesmo.
    environment:
      # O `:?` é proposital: sem senha, o painel responderia 403 a todas as requisições
      # (um container não é loopback), então o compose se recusa a subir em vez de te
      # entregar um container que roda e não serve nada.
      PEPE_DASHBOARD_PASSWORD: ${PEPE_DASHBOARD_PASSWORD:?set this in a .env file}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY}
      TZ: UTC

volumes:
  pepe-data:
  pepe-tools:
```

Os segredos ficam num `.env` ao lado, nunca no arquivo do compose, nunca na imagem. A configuração do Pepe se refere a eles pelo nome (`"api_key": "${OPENROUTER_API_KEY}"`) e os resolve na leitura, então o valor real só existe mesmo no ambiente:

```bash
# .env
PEPE_DASHBOARD_PASSWORD=uma-senha-forte
OPENROUTER_API_KEY=sk-...
```

Todo segredo precisa das duas metades: o valor no `.env` e uma linha em `environment:` dando nome a ele. O Compose lê o `.env` para preencher os `${...}` do próprio arquivo compose, não para popular o container direto, então uma chave que só existe no `.env` nunca chega ao Pepe, e o que você recebe é um "no model configured" sem pista nenhuma do porquê. Acrescente uma linha para cada segredo usado.

A partir desse diretório:

```bash
docker compose up -d
docker compose logs -f          # acompanha o log
docker compose exec pepe bin/pepe remote   # um shell IEx no nó em execução
```

## Colocando isso num servidor

Tudo que foi mostrado até aqui roda numa máquina só, acessível pelo `localhost`. Atrás de um domínio, com TLS e proxy reverso, mais quatro coisas entram em jogo, e nenhuma delas é responsabilidade do Docker. Veja [Publicando em um servidor](/pt-br/docs/deploy/) para Compose atrás do Caddy, Docker Swarm atrás do Traefik, e Kamal.

## Atualizando

Com Compose:

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

Configuração, agentes e conversas voltam junto com o `/data`. As ferramentas do agente, o home dele e cada cache que houver ali dentro voltam com o `/tools`, então nada é reinstalado logo na primeira mensagem. Só o que foi instalado via `apt` não volta, e é exatamente para isso que a imagem existe.

Uma coisa boa de saber: `docker compose down` para os containers e deixa os volumes intactos, que é o que você geralmente quer. Já `docker compose down -v` apaga os volumes também, e junto deles a instalação inteira.

## Um shell dentro do nó

```bash
docker exec -it pepe bin/pepe remote            # ou: docker compose exec pepe bin/pepe remote
```

Isso abre um shell IEx ligado ao release em execução, para inspecionar o sistema por dentro.

Quando o que você precisa é rodar um único comando `pepe`, não um shell inteiro, use `bin/pepe rpc` com `dispatch_attached/1`: são os mesmos comandos que o `pepe` roda em qualquer lugar, só que seguros de executar contra um nó que já está no ar.

```bash
docker exec pepe bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["agent", "list"])'
```

`bin/pepe <comando>` sozinho não funciona aqui: o container é um release puro, e o dispatch de CLI dele só é ativado no binário Burrito, que é distribuído à parte. `bin/pepe rpc`/`remote` acaba sendo o caminho de entrada de qualquer jeito. O motivo de existir `dispatch_attached/1` é que vários comandos, não só `run`/`chat`/`tui` mas também `plugin install`, `eval`, `doctor`, `cron` e outros, mexem em configurações globais pensadas para serem decididas uma única vez, no boot. Num processo de CLI recém-aberto que já vai fechar em seguida, isso é inofensivo; num nó que já está de pé e vai continuar assim, não.
