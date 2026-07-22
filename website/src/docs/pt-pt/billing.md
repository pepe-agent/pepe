---
title: Faturação e limites
description: Mede cada chamada ao modelo por projeto, atribui-lhe um preço, aplica uma margem no que faturas, limita a despesa ou o volume de mensagens mensal, e exporta a fatura do cliente.
---

## Quanto custa uma chamada

Cada chamada ao modelo é medida e atribuída ao projeto do agente, para que possas faturar um cliente ao token. A medição acontece no único ponto por onde passam todas as superfícies (a consola, a API HTTP `/v1`, o WebSocket, o Telegram e todos os canais via webhook), e é acrescentada a um ledger durável, apenas de acréscimo, no mesmo pequeno ficheiro SQLite embutido dos compromissos, das vigilâncias e dos traces, agrupado por projeto (por exemplo, `default`). Esse é o rasto de auditoria daquilo que é cobrado.

O **custo** é `tokens × o preço do modelo`, cotado por 1M de tokens. Um preço é resolvido em camadas, e vence a primeira camada que responder:

1. O **preço manual** definido na ligação do modelo.
2. Uma **cache ao vivo** em `~/.pepe/data/price_book.json`, atualizada a partir do OpenRouter e do mapa de preços do LiteLLM.
3. Uma **semente embutida** de preços conhecidos, que é a saída offline.

Assim um modelo conhecido já fica com preço automaticamente, e só escreves um preço para o substituir ou para preencher uma lacuna. Define preços por modelo em Models, depois Edit, no painel, ou atualiza tu mesmo a cache ao vivo:

```bash
pepe usage prices --refresh
```

Os preços também se atualizam sozinhos uma vez por semana enquanto o `serve` ou um gateway estiver de pé.

O **valor a faturar** é `preço de tabela × a margem do projeto`, o multiplicador opcional por projeto descrito mais abaixo. Aquilo que pagaste e aquilo que faturas são sempre mostrados lado a lado, por isso uma margem nunca esconde o custo real da tua própria equipa.

## Subscrições (ChatGPT Plus, Claude Max)

Uma conversa que corre num login de subscrição não custa nada ao token: o mês foi pago adiantado, quer envies uma mensagem quer envies dez mil. Ainda assim vale exatamente o mesmo para o cliente do que uma que tenha corrido na API paga, por isso o Pepe mantém três números em vez de dois.

| Número | O que significa |
|---|---|
| **Tabela** | `tokens × o preço do modelo`. O que estes tokens teriam custado na API, tenham custado ou não. |
| **A faturar** | `tabela × margem`. O que o cliente paga, calculado a partir do preço de tabela e **não** a partir do que gastaste. |
| **Custo** | O que pagaste realmente. Zero para os tokens que uma subscrição serviu, mais a mensalidade fixa dessa subscrição, contada uma única vez. |

Faturar a partir do preço de tabela é a razão de tudo isto. Um dia a subscrição vai acabar e o mesmo trabalho vai cair na API paga, e nesse dia a fatura do cliente não pode mexer-se. Um preço que acompanha os teus arranjos de fornecimento é um preço que tens de explicar.

Diz ao Pepe quanto uma subscrição te custa e a margem sai certa:

```json
{
  "models": {
    "claude-max": {
      "oauth": { "provider": "anthropic" },
      "monthly_cost": 100
    }
  }
}
```

O bloco `oauth` é escrito por ti pelo `pepe model login`. O `monthly_cost` é quanto essa subscrição te custa por mês. Deixa o `monthly_cost` por definir e a mensalidade simplesmente nunca aparece contra a margem, o que torna a margem reportada um limite superior otimista em vez de um número errado. O `pepe doctor` di-lo.

Se uma chamada correu numa subscrição é decidido **quando ela é registada**, não quando o ledger é lido. Muda uma ligação de um login para uma chave de API e os registos do mês passado continuam a significar o que significavam.

## Faturação e limites

Cada chamada ao modelo é medida por projeto (vê Agentes para perceber o que é um projeto e como criar um). Além dessa medição, um projeto pode opcionalmente ter dois limites mensais independentes, mais uma margem de faturação:

- **Limite de despesa** (`--budget`) - um teto rígido na tua moeda configurada. Assim que o total faturável do mês atinge esse valor, os agentes desse projeto deixam de fazer novas chamadas ao modelo até o limite ser reposto.
- **Limite de mensagens** (`--message-limit`) - um teto rígido em mensagens vindas de clientes. Assim que atingido, os agentes desse projeto deixam de responder a novas mensagens até ser reposto.
- **Margem** (`--markup`) - um multiplicador aplicado sobre o custo do fornecedor para chegar ao valor cobrado ao cliente (ex.: `1.3` = custo do fornecedor +30%). Sem definir, faturas exatamente o custo do fornecedor.

Os três são opcionais e independentes: define qualquer um deles, todos, ou nenhum. O projeto default é um projeto normal para o qual cada comando recorre por omissão, e pode ter os mesmos limites, definidos com `pepe project set default ...`.

### O que conta para o limite de mensagens

O limite de mensagens conta **uma mensagem do cliente, uma vez**, não cada chamada ao modelo que leva a responder-lhe. Se um agente chama três ferramentas antes de responder, isso continua a ser uma mensagem contra o limite, tal como é uma mensagem no chat. Iterações do ciclo de tool-calling, execuções de cron, mensagens de agente para agente e heartbeats nunca contam.

Só conta mensagens vindas de superfícies voltadas para o cliente: Telegram, WhatsApp e outros canais via webhook, o widget incorporável. Exclui deliberadamente a consola TUI, o chat de teste do próprio painel, e a API HTTP, já que esses são o operador a usar o seu próprio runtime, não um cliente a enviar-lhe mensagens.

Um agente individual pode ficar isento do limite de mensagens por completo, o que é útil para algo como um agente de escalonamento sempre ativo que nunca deve ficar em silêncio só porque o resto do projeto atingiu o limite:

```bash
pepe agent add escalation --exempt-message-limit
```

Hoje não há forma pela consola de ativar essa flag num agente que já existe sem mexer nas restantes definições dele, já que `agent add` substitui a definição inteira do agente em vez de corrigir apenas um campo. Altera isso a partir da página de edição do agente no painel.

### Configurar os limites

```bash
pepe project set acme --budget 100
pepe project set acme --message-limit 5000
pepe project set acme --budget 100 --message-limit 5000 --markup 1.3
```

`project set` só altera as flags que passares; o resto das definições do projeto fica intocado. Passa `none` para limpar um limite:

```bash
pepe project set acme --budget none
```

Os mesmos campos são editáveis na página Projetos do painel.

### Repor um limite antes da hora

Um limite repõe-se naturalmente no início de cada mês de faturação, mas não tens de esperar:

```bash
pepe project reset-budget acme
pepe project reset-messages acme
```

A página Projetos do painel tem os mesmos dois botões junto ao badge de cada limite, com uma confirmação a mostrar a contagem atual antes de repor.

Uma reposição não apaga nada: apenas marca um ponto de corte. Despesa ou mensagens registadas antes da reposição continuam no ledger; simplesmente deixam de contar para o limite daí em diante. Isto importa por um motivo específico: **o badge do limite de despesa e o botão de reposição só afetam a contagem operacional usada para bloquear novas chamadas ao modelo.** O registo de faturação real do mês, aquilo que faturarias a um cliente, vive em Usage e reflete sempre o total real, reposto ou não. Se repuseres o limite de despesa de um projeto a meio do mês, o badge da página Projetos vai mostrar um número menor do que a página Usage para o mesmo mês; isso é esperado, não uma inconsistência, já que respondem a perguntas diferentes ("este projeto foi limitado desde a última reposição?" contra "quanto é que este projeto custou realmente este mês?").

## Ler o consumo e exportar faturas

```bash
pepe usage                                   # todos os âmbitos, por mês, por projeto
pepe usage --project acme --granularity day  # um projeto, por dia
pepe usage export --project acme             # uma fatura de cliente (Markdown, ou --format csv)
pepe usage prices --refresh                  # atualiza a cache ao vivo de preços
pepe usage help                              # o percurso completo
```

O `usage export` transforma o mês de um projeto numa fatura de cliente, em Markdown ou CSV. Um agente consegue fazer o mesmo sozinho com a ferramenta `export_invoice`, por isso uma tarefa agendada mensal pode exportar a fatura de cada cliente e enviá-la, usando o Pepe para faturar o próprio uso do Pepe.

No painel, a secção Usage & billing mostra tokens, custo e valor a faturar por ciclo (hora, dia, semana, mês, ano), com desagregações por projeto, modelo e agente. Os preços por modelo definem-se em Models, depois Edit; a margem de um projeto em Projetos, depois Edit.

A moeda é apenas um rótulo. A predefinição é `USD` e alteras isso definindo `"currency"` no `config.json`. Não há conversão cambial, por isso o número está na moeda em que o teu fornecedor cota os preços dele.
