---
title: Telegram
description: Crie e gerencie bots do Telegram conectados a agentes do Pepe.
---

## Telegram

O Telegram é o canal mais rápido de colocar de pé porque não precisa de nenhuma
URL pública. Crie um bot com o @BotFather, copie o token dele e registre.

Configure o bot padrão de forma interativa:

```bash
pepe gateway telegram setup
```

Isso pede o token (você pode colar um token literal ou uma referência
`${ENV_VAR}`), um agente opcional para vincular e uma lista opcional de ids de
chat autorizados a falar com ele.

Você pode rodar mais de um bot, cada um vinculado a um agente diferente:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

As opções do `telegram add`:

- `--token` (obrigatória): o token do bot, literal ou `${ENV_VAR}`.
- `--agent`: qual agente responde. Omita para usar seu agente padrão.
- `--trainers`: de quem esse bot pode aprender para a memória. Omita para todos,
  `none` para ninguém, ou uma lista separada por vírgulas de ids de usuário para
  apenas esses.
- `--heartbeat-minutes` e `--heartbeat-hours`: uma janela periódica opcional de
  despertar (para agentes que verificam coisas em um horário). As horas são uma
  janela local como `8-22`.
- `--progress`: como o bot sinaliza que está trabalhando enquanto uma execução
  está em andamento. Uma entre `reaction` (uma reação na sua mensagem),
  `ambient` (uma linha de atividade), `off` (só o indicador de digitação) ou
  `verbose` (um detalhamento por ferramenta).

Listar e remover bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Rode o consultador em primeiro plano (um consultador por bot):

```bash
pepe gateway telegram
```

Normalmente você não precisa rodar isso separadamente. O `pepe serve` inicia os
bots do Telegram configurados junto com a API HTTP, então um único servidor em
execução cobre todos os canais de uma vez.

<div class="note"><strong>Painel.</strong> A seção Channels do painel lista seus
bots com um selo ao vivo de ativo/inativo, deixa você adicionar um bot, editar
com qual agente ele fala e removê-lo. Ela grava a mesma configuração que a linha
de comando.</div>

### Troque de modelo no meio de uma conversa

`/model` mostra o modelo ativo nesse chat, com um botão **Browse models**
para escolher outro; `/models` vai direto para esse seletor. Uso digitado:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem esse bot fala
```

Qualquer pessoa em uma conversa permitida pode trocar sua própria sessão;
trocar **globalmente** (para todas as conversas que esse bot atende) é
reservado para **treinadores**, a mesma lista que controla o `/learn` e a
memória, então um membro qualquer do chat não consegue reapontar o bot
inteiro para outro modelo em silêncio. Defina `model_switch_locked: true` no
bot para desativar totalmente a troca de modelo por quem não é treinador.
Uma troca de sessão vive só na memória; ela reseta com `/new` ou com um
reinício do servidor, voltando ao que a configuração do próprio agente diz.

### Faça pela conversa

Um agente que tem a ferramenta `manage_channel` pode criar e revincular bots do
Telegram a partir de uma conversa. Como ela edita a configuração, cada chamada
passa pela trava de permissão: o agente propõe a mudança e você confirma antes
de ela ser aplicada.

Você diria:

> Adicione um bot do Telegram chamado sales que fale com o agente de vendas. O
> token está na variável de ambiente SALES_BOT_TOKEN.

O agente chama `manage_channel` com `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"` e `agent: "sales"`. Duas proteções importam aqui:

- **Segredos nunca passam pela conversa.** Você informa o *nome* de uma variável de
  ambiente que guarda o token, nunca o token em si. Ele é armazenado como
  `${SALES_BOT_TOKEN}` e resolvido na hora da leitura, então o segredo cru nunca
  chega ao modelo nem aos registros. Um token cru (que contém dois pontos) é
  rejeitado.
- **O bot padrão protegido é intocável.** A ferramenta só mexe em bots com nome,
  nunca no `default`.

Outras ações do `manage_channel` são `list`, `set_agent` (revincular um bot a
outro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`,
`disable` e `remove`. Depois de qualquer mudança ela reconcilia os consultadores
em execução, então um bot inicia ou para ao vivo, sem reinício.

<div class="note"><strong>Só Telegram.</strong> A ferramenta de chat gerencia
bots do Telegram. As conexões por webhook (WhatsApp, Slack e as demais) são
criadas pela linha de comando, pelo painel ou pelo <code>pepe setup</code>, não
pela conversa.</div>
