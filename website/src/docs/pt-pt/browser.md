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

## Precisa de Chrome

O `browser` precisa de um binário real de Chromium ou Chrome na máquina que corre o Pepe - não vem instalado por omissão, nem no contentor nem fora dele. No Docker, ativa-o ao construir a imagem:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

Fora do Docker, instala o Chromium (ou Chrome) e garante que fica no `PATH`, ou aponta o `PEPE_CHROME_BINARY` para o seu executável. Sem nenhum dos dois, o `browser` devolve um erro claro em vez de falhar em silêncio.
