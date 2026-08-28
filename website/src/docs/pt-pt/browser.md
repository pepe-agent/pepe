---
title: Navegador
description: Um agente consegue controlar um navegador real e sem interface para páginas que exigem JavaScript, sessão iniciada, ou percorrer um fluxo a clicar.
---

O `fetch_url` não passa de um GET simples por HTTP: não consegue correr JavaScript, iniciar sessão nem clicar em nada. É para as páginas que exigem isso que existe a ferramenta `browser`: um Chrome verdadeiro, sem interface, controlado página a página, cuja sessão persiste entre chamadas dentro da mesma conversa até tu próprio a fechares.

Cada conversa recebe a sua própria sessão de navegador, que arranca logo na primeira chamada a `open` e se fecha sozinha ao fim de dez minutos parada, caso nada a termine antes disso. Os cookies e a página atual mantêm-se de uma chamada para a seguinte, por isso um início de sessão, um formulário com várias etapas, ou uma página que só mostra conteúdo depois de um clique funcionam exatamente como funcionariam num separador a sério.

## O que consegue fazer

- **`open`**: navega até um URL, arrancando o navegador da sessão se ainda não houver nenhum a correr. Devolve o título da página, o seu texto visível, e uma lista numerada dos elementos sobre os quais é possível agir.
- **`snapshot`**: descreve de novo a página atual, no mesmo formato do `open`, mas sem navegar. É útil depois de um script na própria página mudar algo sem um carregamento completo.
- **`click`**: clica no elemento numerado `ref`, tal como veio do último `open` ou `snapshot`.
- **`type`**: escreve texto dentro do elemento numerado `ref`.
- **`press`**: prime uma tecla (por exemplo, "Enter"), com a opção de primeiro focar um elemento.
- **`close`**: termina a sessão e liberta o navegador que ela usava.

```
Tu: Entra na página de estado e diz-me se algo está em baixo.

Agente: [browser open: "https://status.example.com/login"]
        [browser type ref=2: "o email da conta"]
        [browser type ref=3: "a palavra-passe da conta"]
        [browser click ref=4]
        [browser snapshot]
Está tudo verde, sem incidentes em aberto neste momento.
```

Os elementos são identificados por número, não por um seletor CSS que terias de escrever tu mesmo: cada `open` ou `snapshot` marca todos os elementos clicáveis ou preenchíveis e devolve o que cada um é e o que diz, pelo que o agente lê "o elemento 4 é o botão de submissão" diretamente daquilo que acabou de lhe ser mostrado.

## Postura de segurança

Um navegador sob o controlo de um agente alcança a mesma rede que a aplicação alcança, e é por isso que o `browser` aplica exatamente a mesma regra do `fetch_url`: só `http`/`https`, e nunca um endereço interno ou privado (loopback, RFC1918, link-local, metadados da nuvem). Essa verificação não para no URL que dás ao `open`: uma ligação para onde a própria página aponta, um redirecionamento por JavaScript, o envio de um formulário, ou os próprios pedidos que a página faz em segundo plano são todos verificados da mesma forma, e barrados antes de o Chrome sequer chegar a enviá-los, não só o endereço que escreveste. E porque um navegador a sério representa uma superfície bem maior do que uma ferramenta só de leitura (os scripts da própria página correm de facto, uma sessão iniciada pode acabar exposta, e usa CPU e memória reais), o `browser` não é uma ferramenta sempre segura: cada chamada passa pelo mesmo pedido de permissão que o `bash`.

## Como arranja um navegador

O `browser` precisa de um binário real de Chrome, Chromium, Edge ou Brave para conseguir controlar alguma coisa. Procura-o por esta ordem:

1. `PEPE_CHROME_BINARY`, se o definires: um caminho explícito vence tudo o resto.
2. O que já estiver instalado, verificando o `PATH` e os locais habituais de instalação de cada sistema (`/Applications` no macOS, `Program Files` e a pasta de instalação por utilizador no Windows), de forma que um navegador que já tenhas é usado tal como está, dentro ou fora de um contentor.
3. **Uma transferência automática, feita uma única vez**, se nenhuma das duas opções anteriores encontrar nada: um build pequeno e sem interface do `chrome-headless-shell`, vindo diretamente do feed oficial Chrome for Testing da Google, guardado em cache dentro de `~/.cache/pepe/browser/` para que isto só aconteça mesmo uma vez por máquina. Podes desligar isto com `PEPE_BROWSER_AUTO_DOWNLOAD=0`, se preferires instalar um navegador por tua conta e ver, em vez disso, um erro bem claro.

A imagem por omissão não traz o próprio pacote do navegador (a mesma lógica que mantém o ffmpeg de fora; consulta o Dockerfile), mas já traz as bibliotecas partilhadas de que um navegador transferido precisa para conseguir arrancar, nas duas arquiteturas que a imagem oficial publica (`amd64` e `arm64`), já que o `browser` é uma ferramenta nativa, e não um extra opcional. É por isso que o passo 3 é o que corre por omissão dentro do Docker, e funciona logo de início: sem argumento de build, sem instalação manual, em qualquer uma das duas arquiteturas, incluindo um Mac com Apple Silicon ou um servidor ARM na nuvem, não só `amd64`. Se preferires antes embutir um navegador completo na imagem, em vez de o transferir em tempo de execução:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

## Fora do Docker, em Linux

Um navegador transferido precisa de bibliotecas partilhadas que o próprio sistema operativo tem de já fornecer, e fora do Docker isso deixa de estar garantido da forma como está na imagem oficial: uma distribuição Linux de ambiente de trabalho normal já costuma tê-las (outras aplicações gráficas dependem das mesmas bibliotecas), mas um servidor mínimo ou sem interface pode não ter. Se o `browser` conseguir transferir o navegador mas falhar ao arrancá-lo, corre:

```
mix pepe browser install
```

Este comando deteta o teu gestor de pacotes (`apt`, `dnf`, `yum`, `pacman`, `apk` ou `zypper`) e instala através dele um navegador completo, pedindo-te a palavra-passe de `sudo` se precisar dela; ao correres o comando já pediste exatamente isso. Depois de instalado, o `browser` passa a encontrá-lo diretamente no `PATH` e deixa de transferir seja o que for.

## Linux em ARM

A Google não publica nenhum build de Chrome for Testing para Linux em ARM, por isso aí o passo 3 usa antes o próprio CDN do Playwright (uma transferência HTTPS comum, tal como a do Chrome for Testing, sem npm nem Node.js envolvidos). A única diferença é que transfere o Chromium completo, em vez do build mais pequeno e sem interface, já que esse CDN não disponibiliza nenhum build sem interface como artefacto à parte. De qualquer das formas, isto acontece sozinho: um servidor ARM não precisa de nenhuma configuração especial, nem dentro do Docker nem fora dele.
