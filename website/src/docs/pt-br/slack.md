---
title: Slack
description: Coloque um agente do Pepe no seu workspace do Slack para as pessoas falarem com ele em canais e mensagens diretas.
---

## Slack

Conectar o Slack permite que as pessoas falem com o agente dentro do próprio
workspace. O Slack entrega as mensagens ao Pepe pela Events API; configure a
conexão pela configuração guiada (ou pelo painel), que pede exatamente os
campos necessários e imprime a URL de retorno para registrar:

```bash
pepe setup
```

Escolha a opção de canal, escolha o Slack e o agente, e informe as credenciais
(uma referência `${ENV_VAR}` é aceita para qualquer segredo). O `config` de
uma conexão contém:

- `bot_token`: o token OAuth do usuário bot (`xoxb-...`), usado como bearer nas
  respostas.
- `signing_secret`: verifica o `X-Slack-Signature` nas requisições de entrada.

No app do Slack, defina a URL de requisição de Event Subscriptions com a URL da
conexão e assine `message.channels` e `app_mention`. O primeiro salvamento
dispara um handshake `url_verification`, que o Pepe responde na hora. As
respostas são publicadas com `chat.postMessage`. Formato da URL de retorno:

```
https://YOUR_HOST/webhooks/default/slack/<slug>
```

Veja [Webhooks](../webhooks/) para os campos compartilhados por toda conexão
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como a rota genérica funciona por baixo dos panos.

### Trocando de modelo

Os comandos `/model` e `/models` deixam as pessoas ver ou trocar qual modelo
de IA responde a elas. Eles só funcionam numa conexão em modo `admin` com
`commands` habilitado; no `support`, são tratados como texto comum. `/models`
lista os modelos disponíveis para o projeto dessa conexão; `/model` mostra o
atual, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da própria
conversa. Trocar **globalmente**, para todos com quem essa conexão fala, é
reservado aos **treinadores**, a mesma lista de confiança que controla a
memória. Defina `model_switch_locked: true` na conexão para desativar
totalmente a troca de modelo por quem não é treinador.
