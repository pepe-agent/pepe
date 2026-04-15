---
title: Webhooks
description: Configure Slack, Discord, Microsoft Teams, Google Chat e canais por webhook genéricos.
---

## Cómo funciona um canal por webhook

Todo canal por webhook, seja qual for a plataforma, é acessível em uma única
rota:

```
https://YOUR_HOST/webhooks/<company>/<provider>/<slug>
```

- `<company>` é o escopo de empresa. Use `root` para o escopo padrão
  (mostrado como "Principal" no painel), ou o identificador de uma empresa para
  isolar uma conexão naquela empresa.
- `<provider>` é o nome da plataforma: `whatsapp`, `slack`, `discord`,
  `msteams` ou `googlechat`.
- `<slug>` é o nome único que você deu à conexão.

Um `GET` para essa URL responde ao aperto de mão de verificação do provedor (o
Pepe devolve o desafio que a plataforma envia quando você registra a URL pela
primeira vez). Um `POST` é um evento de entrada. Em um `POST`, o Pepe resolve a
conexão, verifica a assinatura da requisição contra o segredo que você
configurou, extrai a mensagem, executa o agente vinculado e entrega a resposta
pela própria API do provedor. O trabalho do agente roda em segundo plano para
que a plataforma receba o retorno na hora (provedores como a Meta repetem um
webhook lento).

Há uma única rota genérica. Adicionar um novo provedor nunca adiciona um novo
ponto de acesso.

<div class="note"><strong>Host público.</strong> Canais por webhook precisam de
uma URL que a plataforma consiga alcançar. Exponha sua instância do Pepe atrás
de um proxy reverso ou de um túnel, e defina <code>PEPE_PUBLIC_URL</code> para
que as URLs de retorno que a linha de comando imprime fiquem completas. Para um
túnel rápido durante os testes, rode <code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Esses provedores são configurados pela configuração guiada (ou pelo painel), que
pede exatamente os campos de que cada um precisa e imprime a URL de retorno para
registrar:

```bash
pepe setup
```

Escolha a opção de canal, escolha o provedor e o agente, e informe as
credenciais (uma referência `${ENV_VAR}` é aceita para qualquer segredo). Os
campos obrigatórios de cada provedor estão abaixo.

### Slack

O Slack usa a Events API. O `config` de uma conexão contém:

- `bot_token`: o token OAuth do usuário bot (`xoxb-...`), usado como bearer nas
  respostas.
- `signing_secret`: verifica o `X-Slack-Signature` nas requisições de entrada.

No app do Slack, defina a URL de requisição de Event Subscriptions com a URL da
conexão e assine `message.channels` e `app_mention`. O primeiro salvamento
dispara um aperto de mão `url_verification`, que o Pepe responde na hora. As
respostas são publicadas com `chat.postMessage`. Formato da URL de retorno:

```
https://YOUR_HOST/webhooks/root/slack/<slug>
```

### Discord

O Discord é ligado pelo ponto de acesso de Interactions (comandos de barra),
então ele se encaixa no gateway de webhook em vez de uma conexão persistente. O
`config` de uma conexão contém:

- `public_key`: a chave pública do app (hex), para a verificação de assinatura
  Ed25519 exigida.
- `application_id`: usado para publicar a resposta de acompanhamento.

No app do Discord, aponte "Interactions Endpoint URL" para a URL da conexão e
adicione um comando de barra com uma opção de texto (por exemplo
`/ask prompt:...`). O Discord exige um retorno em três segundos, então o Pepe
responde com uma resposta adiada e pública a resposta real como acompanhamento
assim que o agente termina.

### Microsoft Teams

O Teams usa o Bot Framework. O `config` de uma conexão contém:

- `app_id`: o id do app (cliente) Microsoft do bot.
- `app_password`: o segredo de cliente. Guarde como `${ENV_VAR}`.
- `tenant_id`: o tenant ID do Azure (ou `botframework.com`).

As atividades de entrada chegam como `POST`s. As respostas voltam para a URL de
serviço da atividade com um token de acesso de app gerado a partir das
credenciais de cliente. A menção ao bot é retirada do texto de entrada antes de
o agente ver.

### Google Chat

O Google Chat publica eventos de espaço na URL de retorno. O `config` de uma
conexão contém:

- `access_token`: um token OAuth para a Chat API, usado como bearer nas
  respostas. Guarde como `${ENV_VAR}` e renove por fora.

Só eventos `MESSAGE` de uma pessoa são atendidos. As respostas são publicadas de
volta no espaço pela Chat REST API.

## Por baixo dos panos: o contrato do provedor

Cada canal por webhook é um pequeno módulo que implementa o mesmo contrato, então
todos se comportam de forma coerente e uma nova plataforma é um novo módulo em
vez de uma nova rota. As funções de retorno são:

- `name` e `label`: o segmento de URL do provedor e seu nome para pessoas.
- `config_schema`: os campos que o painel mostra para configurar uma conexão.
- `verify`: responder ao aperto de mão de verificação do `GET`.
- `authenticate`: verificar a assinatura em um `POST` de entrada contra o segredo
  da conexão e o corpo cru da requisição. Uma requisição que falha é descartada.
- `parse`: normalizar a carga da plataforma em zero ou mais mensagens simples.
  Atualizações de estado e recibos de entrega são ignorados.
- `respond` (opcional): produzir uma resposta síncrona quando o protocolo exige
  uma antes de qualquer trabalho do agente, como o desafio `url_verification` do
  Slack ou o ping e o retorno adiado do Discord.
- `deliver`: enviar uma resposta de texto de volta ao remetente.
- `deliver_file` (opcional): enviar um arquivo como anexo.

Se você escrever um plugin que implementa esse contrato, ele se registra como um
novo provedor sob o próprio `name`, acessível na mesma rota `/webhooks/...` sem
fiação extra.
