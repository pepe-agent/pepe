---
title: Faturação e limites
description: Limite a despesa ou o volume de mensagens mensal de uma empresa, aplique uma margem no que factura, e reponha um limite antes da hora.
---

## Faturação e limites

Cada chamada ao modelo é medida por empresa (ver Agentes para perceber o que é uma empresa e como criar uma). Além dessa medição, uma empresa pode opcionalmente ter dois limites mensais independentes, mais uma margem de faturação:

- **Limite de despesa** (`--budget`) - um teto rígido na sua moeda configurada. Assim que o total faturável do mês atinge esse valor, os agentes dessa empresa deixam de fazer novas chamadas ao modelo até o limite ser reposto.
- **Limite de mensagens** (`--message-limit`) - um teto rígido em mensagens vindas de clientes. Assim que atingido, os agentes dessa empresa deixam de responder a novas mensagens até ser reposto.
- **Margem** (`--markup`) - um multiplicador aplicado sobre o custo do fornecedor para chegar ao valor cobrado ao cliente (ex.: `1.3` = custo do fornecedor +30%). Sem definir, factura exactamente o custo do fornecedor.

Os três são opcionais e independentes - defina qualquer um deles, todos, ou nenhum. Root (o âmbito predefinido, sem empresa) pode ter os mesmos limites, definidos com `pepe company set root ...` - não é uma empresa a sério (nunca aparece em `company list`, não pode ser renomeado nem removido), mas também não fica de fora dos limites de faturação.

### O que conta para o limite de mensagens

O limite de mensagens conta **uma mensagem do cliente, uma vez** - não cada chamada ao modelo que leva a responder-lhe. Se um agente chama três ferramentas antes de responder, isso continua a ser uma mensagem contra o limite, tal como é uma mensagem no chat. Iterações do ciclo de tool-calling, execuções de cron, mensagens de agente para agente e heartbeats nunca contam.

Só conta mensagens vindas de superfícies voltadas para o cliente - Telegram, WhatsApp e outros canais via webhook, o widget incorporável. Exclui deliberadamente a consola TUI, o chat de teste do próprio dashboard, e a API HTTP, já que esses são o operador a usar o seu próprio runtime, não um cliente a enviar-lhe mensagens.

Um agente individual pode ficar isento do limite de mensagens por completo - útil para algo como um agente de escalonamento sempre activo que nunca deve ficar em silêncio só porque o resto da empresa atingiu o limite:

```bash
pepe agent add escalation --exempt-message-limit
```

Hoje não há forma pela consola de activar essa flag num agente que já existe sem mexer nas restantes definições dele, já que `agent add` substitui a definição inteira do agente em vez de corrigir apenas um campo. Altere isso a partir da página de edição do agente no dashboard.

### Configurar os limites

```bash
pepe company set acme --budget 100
pepe company set acme --message-limit 5000
pepe company set acme --budget 100 --message-limit 5000 --markup 1.3
```

`company set` só altera as flags que passar - o resto das definições da empresa fica intocado. Passe `none` para limpar um limite:

```bash
pepe company set acme --budget none
```

Os mesmos campos são editáveis na página Companies do dashboard.

### Repor um limite antes da hora

Um limite repõe-se naturalmente no início de cada mês de faturação, mas não precisa de esperar:

```bash
pepe company reset-budget acme
pepe company reset-messages acme
```

A página Companies do dashboard tem os mesmos dois botões junto ao badge de cada limite, com uma confirmação a mostrar a contagem actual antes de repor.

Uma reposição não apaga nada - apenas marca um ponto de corte. Despesa ou mensagens registadas antes da reposição continuam no ledger; simplesmente deixam de contar para o limite daí em diante. Isto importa por um motivo específico: **o badge do limite de despesa e o botão de reposição só afectam a contagem operacional usada para bloquear novas chamadas ao modelo.** O registo de faturação real do mês - o que facturaria a um cliente - vive em Usage e reflecte sempre o total real, reposto ou não. Se repuser o limite de despesa de uma empresa a meio do mês, o badge da página Companies vai mostrar um número menor do que a página Usage para o mesmo mês; isso é esperado, não uma inconsistência, já que respondem a perguntas diferentes ("esta empresa foi limitada desde a última reposição?" contra "quanto é que esta empresa custou realmente este mês?").
