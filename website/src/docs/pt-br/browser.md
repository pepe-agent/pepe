---
title: Navegador
description: Um agente consegue controlar um navegador real, sem interface gráfica, para páginas que exigem JavaScript, login, ou percorrer um fluxo clicando.
---

O `fetch_url` é um GET HTTP simples: não roda JavaScript, não faz login, não
clica em nada. A ferramenta `browser` existe justamente para as páginas que
precisam disso: um Chrome real, sem interface, controlado página por página, e
que persiste entre chamadas dentro da mesma conversa até você mandar fechar.

Cada conversa ganha a própria sessão de navegador, iniciada na primeira
chamada a `open` e encerrada sozinha depois de dez minutos parada, caso nada a
tenha fechado antes disso. Os cookies e a página atual seguem de uma chamada
para a outra, então um login, um formulário de várias etapas, ou uma página
que só revela conteúdo depois de um clique funcionam do mesmo jeito que numa
aba de verdade.

## O que ela consegue fazer

- **`open`**: navega até uma URL (e inicia o navegador da sessão, se nenhum
  estiver rodando ainda). Devolve o título da página, o texto visível dela, e
  uma lista numerada dos elementos em que dá para agir.
- **`snapshot`**: descreve de novo a página atual, no mesmo formato de `open`,
  sem navegar para lugar nenhum. Útil depois que um script da própria página
  muda alguma coisa sem recarregar tudo.
- **`click`**: clica no elemento numerado `ref` do último `open`/`snapshot`.
- **`type`**: digita texto no elemento numerado `ref`.
- **`press`**: pressiona uma tecla (por exemplo, "Enter"), opcionalmente
  focando antes num elemento.
- **`close`**: encerra a sessão e libera o navegador.

```
Você: Entra na página de status e me diz se algo está fora do ar.

Agente: [browser open: "https://status.example.com/login"]
        [browser type ref=2: "o email da conta"]
        [browser type ref=3: "a senha da conta"]
        [browser click ref=4]
        [browser snapshot]
Tudo verde, nenhum incidente aberto agora.
```

Os elementos são identificados por número, não por um seletor CSS que você
teria que escrever na mão: todo `open`/`snapshot` marca cada elemento clicável
ou preenchível e devolve o que ele é e o que diz, então o agente lê "o
elemento 4 é o botão de enviar" direto do que acabou de receber.

## Postura de segurança

Um navegador sob controle de um agente alcança a mesma rede que a aplicação, e
por isso o `browser` segue a mesma regra do `fetch_url`: só `http`/`https`, e
nunca um endereço interno ou privado (loopback, RFC1918, link-local, metadados
de nuvem). Essa checagem não para na URL que você passou para o `open`: um
link para o qual a própria página aponta, um redirecionamento por JavaScript,
o envio de um formulário, ou as requisições que a página faz em segundo plano
são todos checados do mesmo jeito, e barrados antes mesmo de o Chrome chegar a
enviá-los, não só o endereço que você digitou de início. E como um navegador de
verdade é uma superfície bem maior do que uma ferramenta só de leitura (os
scripts da própria página rodam, uma sessão logada pode acabar exposta, e ele
consome CPU e memória de verdade), o `browser` não é uma ferramenta sempre
segura: toda chamada passa pelo mesmo aviso de permissão do `bash`.

## Como ele consegue um navegador

O `browser` precisa de um binário real de Chrome, Chromium, Edge ou Brave para
controlar, e procura nesta ordem:

1. `PEPE_CHROME_BINARY`, se você definir: um caminho explícito ganha de tudo o
   resto.
2. O que já estiver instalado, checando o `PATH` e os locais normais de
   instalação de cada sistema (`/Applications` no macOS, `Program Files` e a
   pasta de instalação por usuário no Windows), então um navegador que você já
   tem é usado do jeito que está, em container ou não.
3. **Um download automático, feito uma única vez**, caso nenhuma das duas
   opções acima encontre nada: um build pequeno e sem interface do
   `chrome-headless-shell`, vindo direto do feed oficial Chrome for Testing do
   Google, guardado em cache em `~/.cache/pepe/browser/` para isso acontecer só
   uma vez por máquina. Desative com `PEPE_BROWSER_AUTO_DOWNLOAD=0` se preferir
   instalar um você mesmo e receber um erro claro em vez disso.

A imagem padrão não inclui o pacote do navegador em si (a mesma lógica que
mantém o ffmpeg de fora; veja o Dockerfile), mas já inclui as bibliotecas
compartilhadas de que um navegador baixado precisa para conseguir arrancar,
nas duas arquiteturas que a imagem oficial publica (`amd64` e `arm64`), já que
o `browser` é uma ferramenta nativa, não um extra opcional. Por isso o passo 3
é o que roda por padrão no Docker, e funciona de cara: sem build arg, sem
instalação manual, em qualquer uma das duas arquiteturas, incluindo um Mac com
Apple Silicon ou um host ARM na nuvem, não só `amd64`. Se preferir embutir um
navegador completo direto na imagem, em vez de baixar em tempo de execução:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

## Fora do Docker, no Linux

Um navegador baixado precisa de bibliotecas compartilhadas que o próprio
sistema base já deve fornecer, e fora do Docker isso não é garantido do jeito
que é na imagem oficial: uma distro desktop normalmente já tem essas
bibliotecas (outros apps com interface gráfica dependem das mesmas), mas um
servidor mínimo ou headless pode não ter. Se o `browser` baixar com sucesso
mas falhar ao arrancar, rode:

```
mix pepe browser install
```

Ele detecta o seu gerenciador de pacotes (`apt`/`dnf`/`yum`/`pacman`/`apk`/`zypper`)
e instala um navegador completo através dele, pedindo sua senha de `sudo` se
precisar; afinal foi exatamente isso que você pediu ao rodar o comando. Uma
vez instalado, o `browser` já acha ele direto no `PATH` e para de baixar
qualquer coisa.

## Linux em ARM

O Google não publica um build de Chrome for Testing para Linux em ARM, então
nesse caso o passo 3 usa o próprio CDN do Playwright (um download HTTPS
comum, igual ao do Chrome for Testing, sem npm nem Node.js envolvidos). A
única diferença é que ele baixa o Chromium completo em vez do build menor sem
interface, já que esse CDN não oferece um build sem interface como artefato
próprio. De qualquer forma, isso é automático: um host ARM não precisa de
nenhuma configuração especial, dentro ou fora do Docker.
