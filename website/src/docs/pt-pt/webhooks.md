---
title: Webhooks
description: Configura Slack, Discord, Microsoft Teams, Google Chat e canais por webhook genéricos.
---

## Cómo funciona um canal por webhook

Todo o canal por webhook, seja qual for a plataforma, está acessível numa única
rota:

```
https://YOUR_HOST/webhooks/<company>/<provider>/<slug>
```

- `<company>` é o âmbito de empresa. Use `root` para o âmbito predefinido
  (apresentado como "Principal" no painel), ou o identificador de uma empresa
  para isolar uma ligação nesse empresa.
- `<provider>` é o nome da plataforma: `whatsapp`, `slack`, `discord`, `msteams`
  ou `googlechat`.
- `<slug>` é o nome único que deu à ligação.

Um `GET` a esse URL responde ao aperto de mão de verificação do fornecedor (o
Pepe devolve o desafio que a plataforma envia quando regista o URL pela primeira
vez). Um `POST` é um evento de entrada. Num `POST`, o Pepe resolve a ligação,
verifica a assinatura do pedido contra o segredo que configurou, extrai a
mensagem, executa o agente associado e entrega a resposta pela própria API do
fornecedor. O trabalho do agente decorre em segundo plano para que a plataforma
receba a confirmação de imediato (fornecedores como a Meta repetem um webhook
lento).

Há uma única rota genérica. Adicionar um novo fornecedor nunca acrescenta um novo
ponto de acesso.

<div class="note"><strong>Host público.</strong> Os canais por webhook precisam
de um URL que a plataforma consiga alcançar. Exponha a sua instância do Pepe atrás
de um proxy inverso ou de um túnel, e defina <code>PEPE_PUBLIC_URL</code> para que
os URLs de retorno que a linha de comandos imprime fiquem completos. Para um túnel
rápido durante os testes, execute <code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Estes fornecedores são configurados pela configuração guiada (ou pelo painel), que
pede exactamente os campos de que cada um precisa e imprime o URL de retorno a
registar:

```bash
pepe setup
```

Escolha a opção de canal, escolha o fornecedor e o agente, e introduza as
credenciais (uma referência `${ENV_VAR}` é aceite para qualquer segredo). Os
campos obrigatórios de cada fornecedor estão abaixo.

### Slack

O Slack usa a Events API. O `config` de uma ligação contém:

- `bot_token`: o token OAuth do utilizador bot (`xoxb-...`), usado como bearer nas
  respostas.
- `signing_secret`: verifica o `X-Slack-Signature` nos pedidos de entrada.

Na aplicação do Slack, defina o URL de pedido de Event Subscriptions com o URL da
ligação e subscreva `message.channels` e `app_mention`. A primeira gravação
dispara um aperto de mão `url_verification`, que o Pepe responde de imediato. As
respostas são publicadas com `chat.postMessage`. Formato do URL de retorno:

```
https://YOUR_HOST/webhooks/root/slack/<slug>
```

### Discord

O Discord é ligado pelo ponto de acesso de Interactions (comandos de barra), por
isso encaixa-se na comporta de webhook em vez de uma ligação persistente. O
`config` de uma ligação contém:

- `public_key`: a chave pública da aplicação (hex), para a verificação de
  assinatura Ed25519 exigida.
- `application_id`: usado para publicar a resposta de seguimento.

Na aplicação do Discord, aponte "Interactions Endpoint URL" para o URL da ligação
e adicione um comando de barra com uma opção de texto (por exemplo
`/ask prompt:...`). O Discord exige uma confirmação em três segundos, por isso o
Pepe responde com uma resposta diferida e pública a resposta real como seguimento
assim que o agente termina.

### Microsoft Teams

O Teams usa o Bot Framework. O `config` de uma ligação contém:

- `app_id`: o id da aplicação (cliente) Microsoft do bot.
- `app_password`: o segredo de cliente. Guarde-o como `${ENV_VAR}`.
- `tenant_id`: o tenant ID do Azure (ou `botframework.com`).

As actividades de entrada chegam como `POST`s. As respostas voltam para o URL de
serviço da actividade com um token de acesso de aplicação gerado a partir das
credenciais de cliente. A menção ao bot é retirada do texto de entrada antes de o
agente o ver.

### Google Chat

O Google Chat publica eventos de espaço no URL de retorno. O `config` de uma
ligação contém:

- `access_token`: um token OAuth para a Chat API, usado como bearer nas respostas.
  Guarde-o como `${ENV_VAR}` e renove-o por fora.

Apenas os eventos `MESSAGE` de uma pessoa são atendidos. As respostas são
publicadas de volta no espaço pela Chat REST API.
