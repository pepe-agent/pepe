---
title: Slack
description: Conecte um app do Slack a um agente do Pepe pela Events API.
---

## Slack

O Slack usa a Events API. Configure pela configuração guiada (ou pelo painel),
que pede exatamente os campos necessários e imprime a URL de retorno para
registrar:

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
https://YOUR_HOST/webhooks/root/slack/<slug>
```

Veja [Webhooks](../webhooks/) para os campos compartilhados por toda conexão
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como a rota genérica funciona por baixo dos panos.

### Trocando de modelo

`/model` e `/models` só disparam numa conexão em modo `admin` com `commands`
habilitado; no `support`, viram texto puro. `/models` lista os modelos
disponíveis para a empresa dessa conexão; `/model` mostra o atual, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar sua própria sessão;
trocar **globalmente** é reservado para **treinadores**, a mesma lista que
controla a memória. Defina `model_switch_locked: true` na conexão para
desativar totalmente a troca de modelo por quem não é treinador.
