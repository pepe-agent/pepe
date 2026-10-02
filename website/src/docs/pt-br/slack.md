---
title: Slack
description: Coloque um agente do Pepe dentro do seu workspace do Slack para as pessoas conversarem com ele em canais e mensagens diretas.
---

## Slack

Ao conectar o Slack, as pessoas passam a poder falar com o agente direto de dentro do
workspace. O Slack entrega as mensagens ao Pepe através da própria Events API.

### Passo a passo

1. **Criar o app no Slack.** Em [api.slack.com/apps](https://api.slack.com/apps) →
   "Create New App" → escolha **"Blank app"** (as outras opções, como "AI agent", vêm
   com scaffolding próprio do Slack que não é necessário aqui — quem faz o papel de
   agente é o Pepe). Selecione o workspace.
2. **Dar permissão ao bot.** Em **OAuth & Permissions → Scopes → Bot Token Scopes**,
   adicione `chat:write`, `app_mentions:read`, `channels:history` e `im:history`. Adicione também `files:read` se as pessoas vão enviar imagens ou arquivos; sem ele o bot não consegue abri-los.
3. **Instalar o app.** Ainda em OAuth & Permissions, clique em "Install to Workspace"
   e copie o **Bot User OAuth Token** (`xoxb-...`).
4. **Pegar o signing secret.** Em **Basic Information → App Credentials**, copie o
   **Signing Secret**.
5. **Registrar a conexão no Pepe:**

   ```bash
   pepe setup
   ```

   Escolha a opção de canal, selecione Slack e o agente, e informe as credenciais
   (para qualquer segredo, uma referência `${ENV_VAR}` também é aceita). O Pepe devolve
   a URL de callback a registrar:

   ```
   https://YOUR_HOST/webhooks/root/slack/<slug>
   ```

   Troque `YOUR_HOST` pelo domínio onde o seu servidor realmente responde (o domínio
   real em produção; `mix pepe serve --tunnel` se for só testar local).
6. **Ligar os eventos no Slack.** No app → **Event Subscriptions** → Enable Events →
   cole a URL do passo anterior (o Slack dispara um handshake de `url_verification` na
   hora, e o Pepe responde sozinho — não precisa de nenhum passo manual). Em "Subscribe
   to bot events", adicione `message.channels`, `app_mention` e `message.im` (esse
   último é o que faz mensagem direta funcionar).
7. **Desligar o Socket Mode.** Apps novos no Slack costumam vir com ele ligado por
   padrão: menu lateral → **Socket Mode**. Enquanto estiver ligado, o Slack manda os
   eventos por WebSocket em vez de bater na sua Request URL — e o Pepe só entende o
   webhook HTTP clássico, então nada chega, silenciosamente, mesmo com tudo o mais
   configurado certo. Deixe desligado.
8. **Salvar.** Na página de Event Subscriptions, clique em "Save Changes" no rodapé
   antes de sair — só colar a URL e sair sem salvar descarta tudo.
9. Se o Slack pedir, **reinstale o app** no workspace (scopes e eventos novos exigem
   isso).
10. **Testar:** convide o bot num canal (`/invite @nome-do-bot`) e mencione ele, ou
    mande uma DM direto.

### Campos da conexão

O `config` de uma conexão traz:

- `bot_token`: o token OAuth do usuário bot (`xoxb-...`), usado como bearer nas respostas.
- `signing_secret`: verifica o `X-Slack-Signature` de cada requisição recebida.

As respostas saem publicadas via `chat.postMessage`.

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
