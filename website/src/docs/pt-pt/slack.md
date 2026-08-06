---
title: Slack
description: Põe um agente do Pepe no teu workspace do Slack para as pessoas falarem com ele em canais e mensagens diretas.
---

## Slack

Ligar o Slack permite que as pessoas falem com o agente dentro do próprio
workspace. O Slack entrega as mensagens ao Pepe através da Events API;
configura a ligação pela configuração guiada (ou pelo painel), que pede
exatamente os campos necessários e imprime o URL de retorno a registar:

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

Os comandos `/model` e `/models` permitem ver ou mudar o modelo de IA que
responde. Só funcionam numa ligação em modo `admin` com `commands` ativado;
no `support`, são tratados como texto normal. `/models` lista os modelos
disponíveis para o projeto desta ligação; `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar o modelo da sua própria
conversa. Mudá-lo **globalmente**, para todos com quem esta ligação fala,
está reservado aos **formadores**, a mesma lista de confiança que rege a
memória. Define `model_switch_locked: true` na ligação para desativar por
completo a mudança de modelo para quem não é formador.
