---
title: Slack
description: Coloca um agente do Pepe dentro do teu workspace do Slack, para as pessoas falarem com ele em canais e em mensagens diretas.
---

## Slack

Ao ligar o Slack, as pessoas passam a poder falar com o agente dentro do próprio
workspace. As mensagens chegam ao Pepe através da Events API do Slack; configura a
ligação pela configuração guiada (ou pelo painel), que pede exatamente os campos
necessários e devolve o URL de callback a registar:

```bash
pepe setup
```

Escolhe a opção de canal, depois o Slack e o agente, e introduz as credenciais (uma
referência `${ENV_VAR}` é aceite para qualquer segredo). O `config` de uma ligação
guarda:

- `bot_token`: o token OAuth do utilizador bot (`xoxb-...`), usado como portador nas respostas.
- `signing_secret`: verifica o `X-Slack-Signature` nos pedidos que chegam.

Na aplicação do Slack, aponta o URL de pedido de Event Subscriptions para o URL da
ligação, e subscreve `message.channels` e `app_mention`. A primeira gravação dispara
um handshake `url_verification`, ao qual o Pepe responde de imediato. As respostas são
publicadas com `chat.postMessage`. O formato do URL de callback é:

```
https://YOUR_HOST/webhooks/default/slack/<slug>
```

Vê [Webhooks](../webhooks/) para os campos que qualquer ligação partilha (`agent`,
`mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`), e para perceberes como
a rota genérica funciona por dentro.

### Mudar de modelo

Os comandos `/model` e `/models` deixam ver ou trocar o modelo de IA que responde. Só
funcionam numa ligação em modo `admin` com `commands` ligado; em `support`, são lidos
como texto normal, sem efeito nenhum. O `/models` lista os modelos disponíveis para o
projeto dessa ligação; o `/model` mostra o atual, ou troca-o:

```text
/model openrouter               # pergunta se é para mudar só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da sua própria conversa.
Já trocá-lo **globalmente**, para todos com quem essa ligação fala, fica reservado aos
**formadores**, a mesma lista de confiança que também controla a memória. Define
`model_switch_locked: true` na ligação para desligar por completo a troca de modelo a
quem não é formador.
