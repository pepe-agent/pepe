---
title: Slack
description: Coloque um agente do Pepe dentro do seu workspace do Slack para as pessoas conversarem com ele em canais e mensagens diretas.
---

## Slack

Ao conectar o Slack, as pessoas passam a poder falar com o agente direto de dentro do
workspace. O Slack entrega as mensagens ao Pepe através da própria Events API; a
conexão em si é configurada pelo fluxo guiado (ou pelo painel), que pede exatamente os
campos necessários e já mostra a URL de callback pronta para registrar:

```bash
pepe setup
```

Escolha a opção de canal, selecione Slack e o agente, e informe as credenciais (para
qualquer segredo, uma referência `${ENV_VAR}` também é aceita). O `config` de uma
conexão traz:

- `bot_token`: o token OAuth do usuário bot (`xoxb-...`), usado como bearer nas respostas.
- `signing_secret`: verifica o `X-Slack-Signature` de cada requisição recebida.

No app do Slack, aponte a URL de requisição de Event Subscriptions para a URL da
conexão e assine `message.channels` e `app_mention`. Salvar isso pela primeira vez
dispara um handshake de `url_verification`, que o Pepe responde na hora. As respostas
saem publicadas via `chat.postMessage`, e o formato da URL de callback é este:

```
https://YOUR_HOST/webhooks/default/slack/<slug>
```

Os campos que toda conexão compartilha (`agent`, `mode`, `trainers`,
`session_ttl_min`, `ephemeral`, `commands`) e como a rota genérica funciona por trás
dos panos estão explicados em [Webhooks](../webhooks/).

### Trocando de modelo

Com os comandos `/model` e `/models`, as pessoas conseguem ver ou trocar qual modelo
de IA está respondendo a elas. Isso só funciona numa conexão em modo `admin` com
`commands` habilitado; no modo `support`, os mesmos comandos são tratados como texto
comum, sem efeito nenhum. `/models` lista os modelos disponíveis para o projeto
daquela conexão; já `/model` mostra o modelo atual, ou faz a troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa dentro de uma conversa permitida pode trocar o modelo da própria
conversa. Já trocar **globalmente**, afetando todo mundo com quem aquela conexão fala,
é privilégio reservado aos **treinadores**, a mesma lista de confiança que controla a
memória. Para desligar de vez a troca de modelo por quem não é treinador, basta
definir `model_switch_locked: true` na conexão.
