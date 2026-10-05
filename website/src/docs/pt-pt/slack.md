---
title: Slack
description: Coloca um agente do Pepe dentro do teu workspace do Slack, para as pessoas falarem com ele em canais e em mensagens diretas.
---

## Slack

Ao ligar o Slack, as pessoas passam a poder falar com o agente dentro do próprio
workspace. As mensagens chegam ao Pepe através da Events API do Slack.

### Passo a passo

1. **Criar a aplicação.** Em [api.slack.com/apps](https://api.slack.com/apps) →
   "Create New App" → escolhe **"Blank app"** (as outras opções, como "AI agent",
   trazem scaffolding próprio do Slack de que não precisas aqui - quem faz de agente é
   o Pepe). Escolhe o teu workspace.
2. **Dar permissões ao bot.** Em **OAuth & Permissions → Scopes → Bot Token Scopes**,
   adiciona `chat:write`, `app_mentions:read`, `channels:history` e `im:history`. Adiciona também `files:read` se as pessoas vão enviar imagens ou ficheiros (sem ele o bot não consegue abri-los), `files:write` para o bot poder enviar ficheiros de volta, `reactions:write` para marcar com um 👀 a mensagem em que está a trabalhar, e `reactions:read` para que um 👍 ou ❤️ numa das suas mensagens conte como feedback. Para este último, subscreve também o evento de bot `reaction_added`.
3. **Instalar a aplicação.** Ainda em OAuth & Permissions, clica em "Install to
   Workspace" e copia o **Bot User OAuth Token** (`xoxb-...`).
4. **Ir buscar o signing secret.** Em **Basic Information → App Credentials**, copia o
   **Signing Secret**.
5. **Registar a ligação no Pepe:**

   ```bash
   pepe setup
   ```

   Escolhe a opção de canal, depois o Slack e o agente, e introduz as credenciais (uma
   referência `${ENV_VAR}` é aceite para qualquer segredo). O Pepe devolve o URL de
   callback a registar:

   ```
   https://YOUR_HOST/webhooks/root/slack/<slug>
   ```

   Troca `YOUR_HOST` pelo domínio onde o teu servidor responde de facto (o domínio real
   em produção; `mix pepe serve --tunnel` se for só para testar em local).
6. **Ligar os eventos no Slack.** Na aplicação → **Event Subscriptions** → Enable
   Events → cola o URL do passo anterior (o Slack dispara logo um handshake de
   `url_verification`, ao qual o Pepe responde sozinho - não é preciso nenhum passo
   manual). Em "Subscribe to bot events", adiciona `message.channels`, `app_mention` e
   `message.im` (este último é o que faz uma mensagem direta funcionar).
7. **Desligar o Socket Mode.** As aplicações novas do Slack costumam vir com isto
   ligado por omissão: barra lateral → **Socket Mode**. Enquanto estiver ligado, o
   Slack envia os eventos por WebSocket em vez de bater no teu Request URL - e o Pepe
   só percebe o webhook HTTP clássico, por isso nada chega, silenciosamente, mesmo com
   tudo o resto bem configurado. Deixa desligado.
8. **Gravar.** Na página de Event Subscriptions, clica em "Save Changes" no rodapé
   antes de saíres - colar o URL e sair sem gravar deita tudo fora.
9. Se o Slack pedir, **reinstala a aplicação** no workspace (scopes e eventos novos
   exigem isso).
10. **Testar:** convida o bot para um canal (`/invite @nome-do-bot`) e menciona-o, ou
    envia-lhe uma mensagem direta.

### Campos da ligação

O `config` de uma ligação guarda:

- `bot_token`: o token OAuth do utilizador bot (`xoxb-...`), usado como portador nas respostas.
- `signing_secret`: verifica o `X-Slack-Signature` nos pedidos que chegam.

As respostas são publicadas com `chat.postMessage`.

Vê [Webhooks](../webhooks/) para os campos que qualquer ligação partilha (`agent`,
`mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`), e para perceberes como
a rota genérica funciona por dentro.

### Mensagens de outras apps

Um canal que recebe o trabalho de outro sistema (um help desk que publica cada novo pedido, um alerta de monitorização) recebe mensagens escritas por uma app, e não por uma pessoa. O Pepe ignora essas por predefinição, para o bot nunca responder a si próprio nem a outros bots. Para responder a uma delas, indica o id do bot (`B...`) ou da app (`A...`) no campo **Responder a estes bots e apps** da ligação (`accept_bots`, separados por vírgulas). Cada mensagem ignorada fica no registo com os seus ids, por isso copias o certo do registo em vez de adivinhar.

As integrações costumam pôr a mensagem toda no anexo com a barra colorida, e não no texto. O Pepe lê o título, o corpo e os campos do anexo como a mensagem. As mensagens do próprio bot nunca são respondidas, mesmo que o id dele conste da lista.

Para manter um canal assim à escuta sem @menção, envia `/mention off` uma vez nele. Continua ligado depois de `/new` e de reiniciar, até alguém enviar `/mention on`.

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
