---
title: Navegador
description: Um agente consegue controlar um navegador real sem interface para páginas que precisam de JavaScript, sessão iniciada, ou percorrer um fluxo a clicar.
---

O `fetch_url` é um simples GET por HTTP: não consegue correr JavaScript, iniciar sessão, nem clicar em nada. A ferramenta `browser` é para as páginas que precisam disso - um Chrome real, sem interface, controlado página a página, que persiste entre chamadas na mesma conversa até o fechares.

Cada conversa tem a sua própria sessão de navegador, que arranca na primeira chamada a `open` e se fecha sozinha ao fim de dez minutos parada, caso nada a termine antes. Os cookies e a página atual mantêm-se de uma chamada para a outra, portanto um início de sessão, um formulário de várias etapas, ou uma página que só revela conteúdo depois de um clique funcionam tal como funcionariam num separador a sério.

## O que faz

- **`open`** - navega até um URL (arranca o navegador da sessão se nenhum estiver a correr ainda). Devolve o título da página, o seu texto visível, e uma lista numerada dos elementos sobre os quais se pode agir.
- **`snapshot`** - descreve de novo a página atual, no mesmo formato de `open`, sem navegar - útil depois de um script na página mudar algo sem um carregamento completo.
- **`click`** - clica no elemento numerado `ref` do último `open`/`snapshot`.
- **`type`** - escreve texto no elemento numerado `ref`.
- **`press`** - prime uma tecla (por exemplo, "Enter"), opcionalmente focando um elemento antes.
- **`close`** - termina a sessão e liberta o seu navegador.

```
Tu: Entra na página de estado e diz-me se algo está em baixo.

Agente: [browser open: "https://status.example.com/login"]
        [browser type ref=2: "o email da conta"]
        [browser type ref=3: "a palavra-passe da conta"]
        [browser click ref=4]
        [browser snapshot]
Está tudo verde, sem incidentes em aberto neste momento.
```

Os elementos são identificados por número, não por um seletor CSS que terias de escrever: cada `open`/`snapshot` marca todos os elementos clicáveis ou preenchíveis e devolve o que são e o que dizem, pelo que o agente lê "o elemento 4 é o botão de submeter" diretamente do que lhe acabou de ser mostrado.

## Postura de segurança

Um navegador sob controlo de um agente alcança a mesma rede que a aplicação, por isso o `browser` aplica a mesma regra do `fetch_url`: apenas `http`/`https`, e nunca um endereço interno ou privado (loopback, RFC1918, link-local, metadados da nuvem). E como um navegador a sério é uma superfície bem maior do que uma ferramenta apenas de leitura (os scripts da própria página correm, uma sessão iniciada pode ficar exposta, usa CPU e memória reais), o `browser` não é sempre-seguro: cada chamada passa pelo mesmo pedido de permissão do `bash`.

## Como consegue um navegador

O `browser` precisa de um binário real de Chrome/Chromium/Edge/Brave para controlar. Procura por esta ordem:

1. `PEPE_CHROME_BINARY`, se o definires - um caminho explícito ganha a tudo o resto.
2. O que já estiver instalado - verificado no `PATH` e nos locais normais de instalação de cada sistema (`/Applications` no macOS, `Program Files` e a pasta de instalação por utilizador no Windows), portanto um navegador que já tenhas é usado tal como está, em contentor ou não.
3. **Uma transferência automática, uma única vez**, se nenhum dos anteriores encontrar nada: um build pequeno e sem interface do `chrome-headless-shell`, vindo do feed oficial Chrome for Testing da Google, guardado em cache em `~/.cache/pepe/browser/` para que isto só aconteça uma vez por máquina. Desliga com `PEPE_BROWSER_AUTO_DOWNLOAD=0` se preferires instalar um tu próprio e ver um erro claro em vez disso.

A imagem por omissão não inclui o pacote do navegador em si (a mesma lógica que mantém o ffmpeg de fora - ver o Dockerfile), mas inclui as bibliotecas partilhadas de que um navegador transferido precisa para arrancar, nas duas arquiteturas que a imagem oficial publica (`amd64` e `arm64`), visto que o `browser` é uma ferramenta nativa, não um extra opcional. Portanto o passo 3 é o que corre por omissão no Docker, e funciona logo à partida: sem build arg, sem instalação manual, em qualquer uma das duas arquiteturas - incluindo um Mac com Apple Silicon ou um anfitrião ARM na nuvem, não só `amd64`. Se preferires embutir um navegador completo na imagem em vez de transferir em tempo de execução:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

## Fora do Docker no Linux

Um navegador transferido precisa de bibliotecas partilhadas que o sistema base já tem de fornecer - fora do Docker isso não está garantido da forma como está na imagem oficial: uma distro de ambiente de trabalho normalmente já as tem (outras aplicações com interface gráfica dependem das mesmas bibliotecas), mas um servidor mínimo ou headless pode não ter. Se o `browser` transferir com sucesso mas falhar ao arrancar, corre:

```
mix pepe browser install
```

Deteta o teu gestor de pacotes (`apt`/`dnf`/`yum`/`pacman`/`apk`/`zypper`) e instala um navegador completo através dele, pedindo a tua palavra-passe de `sudo` se precisar - já pediste exatamente isso ao correres o comando. Depois de instalado, o `browser` encontra-o diretamente no `PATH` e deixa de transferir seja o que for.

## Linux em ARM

A Google não publica um build de Chrome for Testing para Linux em ARM, portanto ali o passo 3 usa o próprio CDN do Playwright em vez disso (uma transferência HTTPS normal, tal como o Chrome for Testing - sem npm nem Node.js envolvido) - a única diferença é que transfere o Chromium completo em vez do build mais pequeno sem interface, visto que esse CDN não disponibiliza um build sem interface como artefacto próprio. De qualquer forma, isto é automático: um anfitrião ARM não precisa de nenhuma configuração especial, nem no Docker nem fora dele.
