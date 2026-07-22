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

## Precisa de Chrome

`browser` precisa de um binário real de Chromium ou Chrome na máquina que roda o Pepe - ele não vem instalado por padrão, nem no container nem fora dele. No Docker, ative na hora de construir a imagem:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

Fora do Docker, instale o Chromium (ou Chrome) e garanta que ele esteja no `PATH`, ou aponte `PEPE_CHROME_BINARY` pro executável dele. Sem nenhum dos dois, `browser` devolve um erro claro em vez de falhar em silêncio.
