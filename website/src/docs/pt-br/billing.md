---
title: Cobrança e limites
description: Limite o gasto ou o volume de mensagens mensal de uma empresa, aplique uma margem no que você cobra, e resete um teto antes da hora.
---

## Cobrança e limites

Toda chamada de modelo é medida por empresa (veja Agentes pra entender o que é uma empresa e como criar uma). Além dessa medição, uma empresa pode opcionalmente carregar dois tetos mensais independentes, mais uma margem de cobrança:

- **Teto de gasto** (`--budget`) - um limite rígido na sua moeda configurada. Assim que o total faturável do mês atinge esse valor, os agentes daquela empresa param de fazer novas chamadas de modelo até o teto resetar.
- **Teto de mensagens** (`--message-limit`) - um limite rígido em mensagens vindas de clientes. Assim que atingido, os agentes daquela empresa param de responder novas mensagens até resetar.
- **Margem** (`--markup`) - um multiplicador aplicado sobre o custo do provedor pra chegar no valor cobrado do cliente (ex: `1.3` = custo do provedor +30%). Sem definir, você cobra exatamente o custo do provedor.

Os três são opcionais e independentes - defina qualquer um deles, todos, ou nenhum. Root (o escopo padrão, sem empresa) pode ter os mesmos tetos, definidos com `pepe company set root ...` - não é uma empresa de verdade (nunca aparece em `company list`, não pode ser renomeado nem removido), mas também não fica de fora dos limites de faturamento.

### O que conta pro teto de mensagens

O teto de mensagens conta **uma mensagem do cliente, uma vez** - não cada chamada de modelo que leva pra responder. Se um agente chama três ferramentas antes de responder, isso ainda é uma mensagem contra o teto, do mesmo jeito que é uma mensagem no chat. Iterações do loop de tool-calling, execuções de cron, mensagens de agente pra agente e heartbeats nunca contam.

Só conta mensagens vindas de superfícies voltadas ao cliente - Telegram, WhatsApp e outros canais via webhook, o widget incorporável. Deliberadamente exclui o console TUI, o chat de teste do próprio dashboard, e a API HTTP, já que esses são o operador usando o próprio runtime, não um cliente mandando mensagem pra ele.

Um agente individual pode ficar isento do teto de mensagens por completo - útil pra algo como um agente de escalonamento sempre ativo que nunca deve ficar mudo só porque o resto da empresa atingiu o teto:

```bash
pepe agent add escalation --exempt-message-limit
```

Hoje não existe forma pelo console de ligar essa flag num agente que já existe sem mexer no resto das configurações dele, já que `agent add` substitui a definição inteira do agente em vez de corrigir só um campo. Alterne isso pela página de edição do agente no dashboard.

### Configurando os tetos

```bash
pepe company set acme --budget 100
pepe company set acme --message-limit 5000
pepe company set acme --budget 100 --message-limit 5000 --markup 1.3
```

`company set` só mexe nas flags que você passar - o resto das configurações da empresa fica intocado. Passe `none` pra limpar um teto:

```bash
pepe company set acme --budget none
```

Os mesmos campos são editáveis na página Companies do dashboard.

### Resetando um teto antes da hora

Um teto reseta naturalmente no início de cada mês de faturamento, mas você não precisa esperar:

```bash
pepe company reset-budget acme
pepe company reset-messages acme
```

A página Companies do dashboard tem os mesmos dois botões ao lado do badge de cada teto, com uma confirmação mostrando a contagem atual antes de resetar.

Um reset não apaga nada - só marca um ponto de corte. Gasto ou mensagens registrados antes do reset continuam no ledger; eles simplesmente param de contar pro teto daí em diante. Isso importa por um motivo específico: **o badge do teto de gasto e o botão de reset só afetam a contagem operacional usada pra bloquear novas chamadas de modelo.** O registro de faturamento real do mês - o que você cobraria de um cliente - vive em Usage e sempre reflete o total real, resetado ou não. Se você resetar o teto de gasto de uma empresa no meio do mês, o badge da página Companies vai mostrar um número menor que a página Usage pro mesmo mês; isso é esperado, não uma inconsistência, já que respondem perguntas diferentes ("essa empresa foi limitada desde o último reset?" contra "quanto essa empresa custou de verdade esse mês?").
