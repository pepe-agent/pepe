---
title: Navegador
description: Um agente consegue controlar um navegador real sem interface para páginas que precisam de JavaScript, login, ou passar por um fluxo com cliques.
---

`fetch_url` é um GET simples por HTTP: não consegue rodar JavaScript, fazer login, nem clicar em nada. A ferramenta `browser` é para as páginas que precisam disso - um Chrome real, sem interface, controlado página por página, que persiste entre chamadas dentro da mesma conversa até você fechar.

Cada conversa tem sua própria sessão de navegador, que começa na primeira chamada a `open` e se fecha sozinha depois de dez minutos parada, se nada a encerrar antes disso. Os cookies e a página atual continuam de uma chamada pra outra, então um login, um formulário de várias etapas, ou uma página que só revela conteúdo depois de um clique funcionam do jeito que funcionariam numa aba de verdade.

## O que ela faz

- **`open`** - navega até uma URL (inicia o navegador da sessão se nenhum estiver rodando ainda). Devolve o título da página, seu texto visível, e uma lista numerada dos elementos em que dá pra agir.
- **`snapshot`** - descreve de novo a página atual, no mesmo formato de `open`, sem navegar - útil depois que um script na página muda algo sem um carregamento completo.
- **`click`** - clica no elemento numerado `ref` do último `open`/`snapshot`.
- **`type`** - digita texto no elemento numerado `ref`.
- **`press`** - pressiona uma tecla (por exemplo, "Enter"), opcionalmente focando um elemento antes.
- **`close`** - encerra a sessão e libera o navegador.

```
Você: Entra na página de status e me diz se algo está fora do ar.

Agente: [browser open: "https://status.example.com/login"]
        [browser type ref=2: "o email da conta"]
        [browser type ref=3: "a senha da conta"]
        [browser click ref=4]
        [browser snapshot]
Tudo verde, nenhum incidente aberto agora.
```

Os elementos são identificados por número, não por um seletor CSS que você teria que escrever: todo `open`/`snapshot` marca cada elemento clicável ou preenchível e devolve o que ele é e o que diz, então o agente lê "o elemento 4 é o botão de enviar" direto do que acabou de receber.

## Postura de segurança

Um navegador sob controle de um agente alcança a mesma rede que a aplicação, então `browser` segue a mesma regra do `fetch_url`: só `http`/`https`, e nunca um endereço interno ou privado (loopback, RFC1918, link-local, metadados de nuvem). E como um navegador de verdade é uma superfície bem maior que uma ferramenta só de leitura (os scripts da própria página rodam, uma sessão logada pode ficar exposta, ele usa CPU e memória de verdade), `browser` não é sempre-segura: toda chamada passa pelo mesmo aviso de permissão do `bash`.

## Como ele consegue um navegador

`browser` precisa de um binário real de Chrome/Chromium/Edge/Brave pra controlar. Ele procura nesta ordem:

1. `PEPE_CHROME_BINARY`, se você definir - um caminho explícito ganha de tudo o resto.
2. O que já estiver instalado - checado no `PATH` e nos locais normais de instalação de cada sistema (`/Applications` no macOS, `Program Files` e a pasta de instalação por usuário no Windows), então um navegador que você já tem é usado do jeito que está, em container ou não.
3. **Um download automático, uma única vez**, se nenhum dos dois anteriores achar nada: um build pequeno e sem interface do `chrome-headless-shell`, vindo direto do feed oficial Chrome for Testing do Google, guardado em cache em `~/.cache/pepe/browser/` pra isso só acontecer uma vez por máquina. Desliga com `PEPE_BROWSER_AUTO_DOWNLOAD=0` se preferir instalar um você mesmo e ver um erro claro em vez disso.

A imagem padrão não inclui o pacote do navegador em si (a mesma lógica que mantém o ffmpeg de fora - ver o Dockerfile), mas inclui as bibliotecas compartilhadas que o `chrome-headless-shell` precisa pra arrancar depois de baixado, já que `browser` é uma ferramenta nativa, não um extra opcional. Então o passo 3 é o que roda por padrão no Docker, e funciona direto: sem precisar de nenhum build arg, num host `amd64` (o Google não publica um build de Chrome for Testing pra Linux em ARM - ver abaixo). Se preferir embutir um navegador completo na imagem em vez de baixar em tempo de execução:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

## Linux em ARM

O Chrome for Testing não tem build pra Linux ARM, então o passo 3 não ajuda ali - `browser` devolve um erro claro de "plataforma não suportada" em vez de falhar em silêncio. Instale o Chromium você mesmo via o gerenciador de pacotes do seu sistema e coloque no `PATH`, ou defina `PEPE_CHROME_BINARY`.
