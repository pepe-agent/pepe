---
title: Slack
description: Liga uma aplicação do Slack a um agente do Pepe através da Events API.
---

## Slack

O Slack usa a Events API. Configura pela configuração guiada (ou pelo painel),
que pede exatamente os campos necessários e imprime o URL de retorno a
registar:

```bash
pepe setup
```

Escolhe a opção de canal, escolhe o Slack e o agente, e introduz as
credenciais (uma referência `${ENV_VAR}` é aceite para qualquer segredo). O
`config` de uma ligação contém:

- `bot_token`: o token OAuth do utilizador bot (`xoxb-...`), usado como bearer
  nas respostas.
- `signing_secret`: verifica o `X-Slack-Signature` nos pedidos de entrada.

Na aplicação do Slack, define o URL de pedido de Event Subscriptions com o URL
da ligação e subscreve `message.channels` e `app_mention`. A primeira gravação
dispara um handshake `url_verification`, que o Pepe responde de imediato.
As respostas são publicadas com `chat.postMessage`. Formato do URL de retorno:

```
https://YOUR_HOST/webhooks/default/slack/<slug>
```

Vê [Webhooks](../webhooks/) para os campos partilhados por toda a ligação
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como funciona a rota genérica por dentro.

### Mudar de modelo

`/model` e `/models` só disparam numa ligação em modo `admin` com `commands`
ativado; no `support`, são texto simples. `/models` lista os modelos
disponíveis para o projeto desta ligação; `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão;
mudá-lo **globalmente** está reservado a **formadores**, a mesma lista que
rege a memória. Define `model_switch_locked: true` na ligação para desativar
por completo a mudança de modelo para quem não é formador.
