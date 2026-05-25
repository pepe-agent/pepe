---
title: Cobrança e limites
description: Meça cada chamada de modelo por projeto, precifique, aplique uma margem no que você cobra, limite o gasto ou o volume de mensagens mensal, e exporte a fatura do cliente.
---

## Quanto custa uma chamada

Toda chamada de modelo é medida e atribuída ao projeto do agente, então você consegue cobrar um cliente por token. A medição acontece no único ponto por onde passam todas as superfícies (o console, a API HTTP `/v1`, o WebSocket, o Telegram e todo canal via webhook), e ela vai sendo anexada a um ledger durável, só de acréscimo, em `~/.pepe/data/usage/<slug>/YYYY-MM.jsonl`. Esse arquivo é a trilha de auditoria do que é cobrado.

O **custo** é `tokens × o preço do modelo`, cotado por 1M de tokens. Um preço é resolvido em camadas, e a primeira camada que responde vence:

1. O **preço manual** definido na conexão do modelo.
2. Um **cache ao vivo** em `~/.pepe/data/price_book.json`, atualizado a partir do OpenRouter e do mapa de preços do LiteLLM.
3. Uma **semente embutida** de preços conhecidos, que é a saída offline.

Assim um modelo conhecido já é precificado sozinho, e você só digita um preço para sobrescrever algum ou para preencher uma lacuna. Defina preços por modelo em Models, depois Edit, no painel, ou atualize o cache ao vivo você mesmo:

```bash
pepe usage prices --refresh
```

Os preços também se atualizam sozinhos uma vez por semana enquanto o `serve` ou um gateway estiver de pé.

O **valor a cobrar** é `preço de tabela × a margem do projeto`, o multiplicador opcional por projeto descrito abaixo. O que você pagou e o que você cobra são sempre mostrados lado a lado, então uma margem nunca esconde o custo real do seu próprio time.

## Assinaturas (ChatGPT Plus, Claude Max)

Uma conversa que roda num login de assinatura não custa nada por token: o mês foi pago adiantado, quer você mande uma mensagem ou dez mil. Mesmo assim ela vale exatamente o mesmo para o cliente que uma que rodou na API paga, então o Pepe mantém três números em vez de dois.

| Número | O que significa |
|---|---|
| **Tabela** | `tokens × o preço do modelo`. O que esses tokens teriam custado na API, tendo custado ou não. |
| **A cobrar** | `tabela × margem`. O que o cliente paga, calculado a partir do preço de tabela e **não** a partir do que você gastou. |
| **Custo** | O que você pagou de verdade. Zero para os tokens que uma assinatura serviu, mais a mensalidade fixa daquela assinatura, contada uma única vez. |

Cobrar a partir do preço de tabela é a razão de tudo isso. Um dia a assinatura vai acabar e o mesmo trabalho vai cair na API paga, e nesse dia a fatura do cliente não pode se mexer. Um preço que acompanha os seus arranjos de fornecimento é um preço que você tem que explicar.

Diga ao Pepe quanto uma assinatura custa para você e a margem sai certa:

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

O bloco `oauth` é escrito para você pelo `pepe model login`. O `monthly_cost` é quanto aquela assinatura custa por mês. Deixe o `monthly_cost` sem definir e a mensalidade simplesmente nunca aparece contra a margem, o que torna a margem informada um limite superior otimista em vez de um número errado. O `pepe doctor` avisa isso.

Se uma chamada rodou numa assinatura é decidido **quando ela é registrada**, não quando o ledger é lido. Troque uma conexão de um login para uma chave de API e os registros do mês passado continuam significando o que significavam.

## Cobrança e limites

Toda chamada de modelo é medida por projeto (veja Projetos para entender o que é um projeto e como criar um). Além dessa medição, um projeto pode opcionalmente carregar dois tetos mensais independentes, mais uma margem de cobrança:

- **Teto de gasto** (`--budget`) - um limite rígido na sua moeda configurada. Assim que o total faturável do mês atinge esse valor, os agentes daquele projeto param de fazer novas chamadas de modelo até o teto resetar.
- **Teto de mensagens** (`--message-limit`) - um limite rígido em mensagens vindas de clientes. Assim que atingido, os agentes daquele projeto param de responder novas mensagens até resetar.
- **Margem** (`--markup`) - um multiplicador aplicado sobre o custo do provedor para chegar no valor cobrado do cliente (ex: `1.3` = custo do provedor +30%). Sem definir, você cobra exatamente o custo do provedor.

Os três são opcionais e independentes: defina qualquer um deles, todos, ou nenhum. O projeto default é um projeto normal como qualquer outro, então pode carregar os mesmos tetos, definidos com `pepe project set default ...`. Ele aparece em `project list`, tem billing próprio, e não fica de fora dos limites de faturamento.

### O que conta para o teto de mensagens

O teto de mensagens conta **uma mensagem do cliente, uma vez**, não cada chamada de modelo que leva para responder. Se um agente chama três ferramentas antes de responder, isso ainda é uma mensagem contra o teto, do mesmo jeito que é uma mensagem no chat. Iterações do loop de tool-calling, execuções de cron, mensagens de agente para agente e heartbeats nunca contam.

Só conta mensagens vindas de superfícies voltadas ao cliente: Telegram, WhatsApp e outros canais via webhook, o widget incorporável. Deliberadamente exclui o console TUI, o chat de teste do próprio painel, e a API HTTP, já que esses são o operador usando o próprio runtime, não um cliente mandando mensagem para ele.

Um agente individual pode ficar isento do teto de mensagens por completo, o que é útil para algo como um agente de escalonamento sempre ativo que nunca deve ficar mudo só porque o resto do projeto atingiu o teto:

```bash
pepe agent add escalation --exempt-message-limit
```

Hoje não existe forma pela CLI de ligar essa flag num agente que já existe sem mexer no resto das configurações dele, já que `agent add` substitui a definição inteira do agente em vez de corrigir só um campo. Alterne isso pela página de edição do agente no painel.

### Configurando os tetos

```bash
pepe project set acme --budget 100
pepe project set acme --message-limit 5000
pepe project set acme --budget 100 --message-limit 5000 --markup 1.3
```

`project set` só mexe nas flags que você passar; o resto das configurações do projeto fica intocado. Passe `none` para limpar um teto:

```bash
pepe project set acme --budget none
```

Os mesmos campos são editáveis na página Projects do painel.

### Resetando um teto antes da hora

Um teto reseta naturalmente no início de cada mês de faturamento, mas você não precisa esperar:

```bash
pepe project reset-budget acme
pepe project reset-messages acme
```

A página Projects do painel tem os mesmos dois botões ao lado do badge de cada teto, com uma confirmação mostrando a contagem atual antes de resetar.

Um reset não apaga nada; ele só marca um ponto de corte. Gasto ou mensagens registrados antes do reset continuam no ledger; eles simplesmente param de contar para o teto daí em diante. Isso importa por um motivo específico: **o badge do teto de gasto e o botão de reset só afetam a contagem operacional usada para bloquear novas chamadas de modelo.** O registro de faturamento real do mês (o que você cobraria de um cliente) vive em Usage e sempre reflete o total real, resetado ou não. Se você resetar o teto de gasto de um projeto no meio do mês, o badge da página Projects vai mostrar um número menor que a página Usage para o mesmo mês; isso é esperado, não uma inconsistência, já que respondem perguntas diferentes ("esse projeto foi limitado desde o último reset?" contra "quanto esse projeto custou de verdade esse mês?").

## Ler o consumo e exportar faturas

```bash
pepe usage                                   # todos os projetos, por mês, por projeto
pepe usage --project acme --granularity day  # um projeto, por dia
pepe usage export --project acme             # uma fatura de cliente (Markdown, ou --format csv)
pepe usage prices --refresh                  # atualiza o cache ao vivo de preços
pepe usage help                              # o passo a passo completo
```

O `usage export` transforma o mês de um projeto numa fatura de cliente, em Markdown ou CSV. Um agente consegue fazer isso sozinho com a ferramenta `export_invoice`, então uma tarefa agendada mensal pode exportar a fatura de cada cliente e enviá-la, usando o Pepe para cobrar pelo próprio uso do Pepe.

No painel, a seção Usage & billing mostra tokens, custo e valor a cobrar por ciclo (hora, dia, semana, mês, ano), com quebras por projeto, modelo e agente. Os preços por modelo são definidos em Models, depois Edit; a margem de um projeto em Projects, depois Edit.

A moeda é apenas um rótulo. O padrão é `USD` e você muda definindo `"currency"` no `config.json`. Não há conversão de câmbio, então o número está na moeda em que o seu provedor cota os preços dele.
