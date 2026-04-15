---
title: Telegram
description: Cria e gere bots do Telegram ligados a agentes do Pepe.
---

## Telegram

O Telegram é o canal mais rápido de pôr de pé porque não precisa de qualquer URL
público. Crie um bot com o @BotFather, copie o respectivo token e registe-o.

Configure o bot predefinido de forma interactiva:

```bash
pepe gateway telegram setup
```

Isto pede o token (pode colar um token literal ou uma referência `${ENV_VAR}`),
um agente opcional para associar e uma lista opcional de ids de conversa
autorizados a falar com ele.

Pode executar mais do que um bot, cada um associado a um agente diferente:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

As opções do `telegram add`:

- `--token` (obrigatória): o token do bot, literal ou `${ENV_VAR}`.
- `--agent`: qual o agente que responde. Omita para usar o seu agente
  predefinido.
- `--trainers`: de quem este bot pode aprender para a memória. Omita para todos,
  `none` para ninguém, ou uma lista separada por vírgulas de ids de utilizador
  para apenas esses.
- `--heartbeat-minutes` e `--heartbeat-hours`: uma janela periódica opcional de
  activação (para agentes que verificam coisas segundo um horário). As horas são
  uma janela local como `8-22`.
- `--progress`: como o bot sinaliza que está a trabalhar enquanto uma execução
  decorre. Uma entre `reaction` (uma reacção na sua mensagem), `ambient` (uma
  linha de actividade), `off` (apenas o indicador de escrita) ou `verbose` (um
  detalhe por ferramenta).

Listar e remover bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Execute o consultador em primeiro plano (um consultador por bot):

```bash
pepe gateway telegram
```

Normalmente não precisa de executar isto em separado. O `pepe serve` arranca com
os bots do Telegram configurados a par da API HTTP, por isso um único servidor em
execução cobre todos os canais de uma vez.

<div class="note"><strong>Painel.</strong> A secção Channels do painel lista os
seus bots com um distintivo ao vivo de activo/inactivo, permite-lhe adicionar um
bot, editar com que agente ele fala e removê-lo. Grava a mesma configuração que a
linha de comandos.</div>

### Muda de modelo a meio de uma conversa

`/model` mostra o modelo activo nesse chat, com um botão **Browse models**
para escolher outro; `/models` vai directo a esse selector. Utilização
escrita:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem este bot fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão;
mudá-lo **globalmente** (para todas as conversas que este bot atende) está
reservado a **formadores** - a mesma lista que rege o `/learn` e a memória -
por isso um membro qualquer do chat não consegue reapontar todo o bot para
outro modelo em silêncio. Defina `model_switch_locked: true` no bot para
desactivar por completo a mudança de modelo para quem não é formador. Uma
alteração de sessão vive só em memória - repõe-se com `/new` ou com um
reinício do servidor, voltando ao que a configuração própria do agente
disser.

### Faça pela conversa

Um agente que tenha a ferramenta `manage_channel` consegue criar e reassociar
bots do Telegram a partir de uma conversa. Como edita a configuração, cada
chamada passa pela cancela de permissão: o agente propõe a alteração e o
utilizador confirma antes de ela ser aplicada.

Diria:

> Adiciona um bot do Telegram chamado sales que fale com o agente de vendas. O
> token está na variável de ambiente SALES_BOT_TOKEN.

O agente invoca `manage_channel` com `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"` e `agent: "sales"`. Aqui importam duas
salvaguardas:

- **Os segredos nunca passam pela conversa.** Fornece o *nome* de uma variável de
  ambiente que guarda o token, nunca o token em si. É armazenado como
  `${SALES_BOT_TOKEN}` e resolvido no momento da leitura, por isso o segredo em
  bruto nunca chega ao modelo nem aos registos. Um token em bruto (que contém
  dois pontos) é rejeitado.
- **O bot predefinido protegido é intocável.** A ferramenta só mexe em bots com
  nome, nunca no `default`.

Outras acções do `manage_channel` são `list`, `set_agent` (reassociar um bot a
outro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`,
`disable` e `remove`. Após qualquer alteração, reconcilia os consultadores em
execução, por isso um bot arranca ou pára ao vivo, sem reinício.

<div class="note"><strong>Apenas Telegram.</strong> A ferramenta de conversa
gere bots do Telegram. As ligações por webhook (WhatsApp, Slack e as restantes)
são criadas pela linha de comandos, pelo painel ou pelo <code>pepe setup</code>,
não pela conversa.</div>
