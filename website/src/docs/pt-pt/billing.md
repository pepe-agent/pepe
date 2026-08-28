---
title: Faturação e limites
description: Mede cada chamada ao modelo por projeto, atribui-lhe um preço, aplica uma margem ao que faturas, limita a despesa ou o volume de mensagens de um projeto por mês, e exporta a fatura de um cliente.
---

## Quanto custa uma chamada

Cada chamada ao modelo é medida e atribuída ao projeto do agente que a fez, o que te permite faturar um cliente ao token. Nenhuma superfície escapa a esta medição: a consola, a API HTTP `/v1`, o WebSocket, o Telegram e todos os canais por webhook passam todos pelo mesmo ponto. Cada chamada é acrescentada a um livro-razão que nunca é reescrito, guardado no mesmo pequeno ficheiro SQLite embutido onde vivem os compromissos, os watches e os traces, agrupado por projeto (por exemplo, `default`). É esse o rasto de auditoria do que acaba por ser cobrado.

O **custo** é `tokens × o preço do modelo`, cotado por 1M de tokens. Um preço resolve-se em camadas, e ganha a primeira camada que tiver resposta:

1. O **preço manual** definido na ligação do modelo.
2. Uma **cache ao vivo** em `~/.pepe/data/price_book.json`, atualizada a partir do OpenRouter e do mapa de preços do LiteLLM.
3. Uma **semente incorporada** de preços já conhecidos, que serve de recurso quando não há ligação à internet.

Um modelo conhecido fica assim com preço logo à partida, e só precisas de escrever um preço quando queres substituir um valor ou preencher uma lacuna. Define preços por modelo em Models, depois Edit, no painel, ou atualiza tu mesmo a cache ao vivo:

```bash
pepe usage prices --refresh
```

Os preços também se atualizam sozinhos, uma vez por semana, sempre que o `serve` ou um gateway estiver a correr.

**O valor a faturar** é `preço de tabela × a margem do projeto`, esse multiplicador opcional por projeto descrito mais abaixo. O que pagaste e o que faturas aparecem sempre lado a lado, por isso uma margem nunca esconde o custo real da tua própria equipa.

## Subscrições (ChatGPT Plus, Claude Max)

Uma conversa que corre sobre o login de uma subscrição não custa nada por token: o mês já foi pago adiantado, quer envies uma mensagem quer envies dez mil. Ainda assim, vale exatamente o mesmo para o cliente do que uma conversa que tivesse corrido na API paga, e é por isso que o Pepe guarda três números em vez de dois.

| Número | O que significa |
|---|---|
| **Tabela** | `tokens × o preço do modelo`. O que estes tokens teriam custado na API, quer tenham custado isso quer não. |
| **A faturar** | `tabela × margem`. O que o cliente paga, calculado a partir do preço de tabela e **não** a partir do que tu de facto gastaste. |
| **Custo** | O que realmente pagaste. Zero para os tokens que uma subscrição serviu, mais a mensalidade fixa dessa subscrição, contada uma única vez. |

Faturar a partir do preço de tabela é precisamente o ponto de tudo isto. A subscrição há de acabar um dia, e o mesmo trabalho vai cair de volta na API paga; nesse dia, a fatura do cliente não pode mexer nem um pouco. Um preço que segue os teus acordos de fornecimento é um preço que depois tens de andar a justificar.

Diz ao Pepe quanto uma subscrição te custa, e a margem sai certa sozinha:

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

O bloco `oauth` é escrito automaticamente pelo `pepe model login`. O `monthly_cost` é quanto essa subscrição te custa por mês. Se deixares `monthly_cost` por definir, a mensalidade simplesmente nunca entra na conta da margem, o que torna a margem reportada um limite superior otimista em vez de um número errado, e o `pepe doctor` avisa-te disso.

Se uma chamada correu ou não sobre uma subscrição é algo decidido **no momento em que fica registada**, não no momento em que o livro-razão é lido. Muda uma ligação de um login para uma chave de API e os registos do mês passado continuam a significar exatamente o que significavam.

## Faturação e limites

Cada chamada ao modelo é medida por projeto (consulta Agentes para perceberes o que é um projeto e como criar um). Além dessa medição, um projeto pode opcionalmente ter dois tetos mensais independentes, mais uma margem de faturação:

- **Teto de despesa** (`--budget`): um limite rígido na tua moeda configurada. Assim que o total faturável do mês em curso o atinge, os agentes desse projeto param de fazer novas chamadas ao modelo até o teto ser reposto.
- **Teto de mensagens** (`--message-limit`): um limite rígido sobre mensagens vindas de clientes. Assim que é atingido, os agentes desse projeto deixam de responder a novas mensagens recebidas até haver reposição.
- **Margem** (`--markup`): um multiplicador aplicado ao custo do fornecedor para chegar ao que cobras ao cliente (por exemplo, `1.3` equivale ao custo do fornecedor mais 30%). Se não a definires, faturas exatamente o custo do fornecedor.

Os três são opcionais e independentes entre si: podes definir um, todos, ou nenhum. O projeto default carrega os mesmos tetos que qualquer outro, definidos com `pepe project set default ...` (ou o nome que lhe tiveres dado, se o renomeaste).

### O que conta para o teto de mensagens

O teto de mensagens conta **uma mensagem vinda do cliente, uma única vez**, e não cada chamada ao modelo que é precisa para lhe responder. Se um agente chama três ferramentas antes de responder, isso continua a valer como uma só mensagem para efeitos do teto, tal como conta como uma só mensagem no chat. Iterações do ciclo de chamada de ferramentas, execuções de cron, mensagens trocadas entre agentes e heartbeats nunca entram nesta conta.

Só contam mensagens vindas de superfícies viradas para o cliente: Telegram, WhatsApp e outros canais por webhook, o widget incorporável. Ficam deliberadamente de fora a consola do `pepe chat`, o chat de teste do próprio painel e a API HTTP, já que nesses casos é o operador a usar o seu próprio runtime, não um cliente a enviar-lhe mensagens.

Um agente específico pode ficar completamente isento do teto de mensagens, o que é útil para algo como um agente de escalonamento sempre ativo, que nunca pode ficar calado só porque o resto do projeto atingiu o seu teto:

```bash
pepe agent add escalation --exempt-message-limit
```

Não há hoje nenhuma forma, pela CLI, de ligar essa flag num agente que já existe sem mexer no resto das suas definições, já que o `agent add` substitui a definição inteira do agente em vez de corrigir apenas um campo. Para isso, usa antes a página de edição do agente no painel.

### Configurar os tetos

```bash
pepe project set acme --budget 100
pepe project set acme --message-limit 5000
pepe project set acme --budget 100 --message-limit 5000 --markup 1.3
```

O `project set` só toca nas flags que passares; o resto das definições do projeto fica intocado. Passa `none` para limpar um teto:

```bash
pepe project set acme --budget none
```

Os mesmos campos podem ser editados na página Projetos do painel.

### Repor um teto antes da hora

Um teto repõe-se sozinho no início de cada mês de faturação, mas não precisas de esperar por isso:

```bash
pepe project reset-budget acme
pepe project reset-messages acme
```

A página Projetos do painel tem os mesmos dois botões junto ao selo de cada teto, com uma confirmação que mostra a contagem atual antes de repor.

Repor não apaga nada, apenas marca um ponto de corte. A despesa ou as mensagens registadas antes da reposição continuam no livro-razão; simplesmente deixam de contar para o teto a partir dali. Isto importa por um motivo muito concreto: **o selo do teto de despesa e o botão de reposição só afetam a contagem operacional usada para bloquear novas chamadas ao modelo.** O registo de faturação real do mês, aquele que na prática se transforma na fatura do cliente, vive em Usage, e reflete sempre o total real, tenha havido reposição ou não. Se repuseres o teto de despesa de um projeto a meio do mês, o selo da página Projetos vai mostrar um número mais baixo do que o da página Usage para esse mesmo mês. Isso é o esperado, não uma inconsistência: são perguntas diferentes ("este projeto ficou travado desde a última reposição?" contra "quanto é que este projeto custou de facto este mês?").

## Saldo pré-pago (dinheiro real creditado, não um teto mensal)

O teto de despesa acima descrito repõe-se sozinho todos os meses: é um travão, não é dinheiro. Um **saldo pré-pago** é outra coisa: fundos reais creditados (um pagamento recebido, ou adicionado à mão), consumidos à medida da despesa faturável real, recusando novas chamadas ao modelo assim que chega a zero e mantendo-se recusado até voltar a ser creditado. É útil para correr o Pepe como serviço pago: o agente de um cliente trabalha até esgotar o que foi pago, não até o calendário virar o mês.

Um projeto que nunca chegou a ser creditado fica completamente por afetar: só o teto de despesa acima se aplica a ele, exatamente como se este mecanismo nem existisse. No momento em que algo credita um projeto, passa a existir um saldo para ele, e os dois travões passam a valer: tanto o teto de despesa como o saldo chegar a zero param novas chamadas.

```bash
pepe project credit acme 50          # credita 50€ (ou a moeda que tiveres configurado)
pepe project balance acme            # mostra o saldo atual
```

A página Projetos do painel mostra um selo de saldo (azul, ou vermelho assim que se esgota) ao lado do selo do teto de despesa do projeto, a partir do momento em que alguma vez foi creditado.

### Creditar automaticamente a partir de um pagamento

Um webhook genérico, sem ligação a nenhum processador de pagamento em particular, credita um saldo a partir de qualquer processador; é deliberadamente independente do SDK ou do esquema de assinatura de um processador específico. Aponta para lá o webhook do teu próprio processador de pagamento (uma pequena função de retransmissão, um passo no Zapier ou no Make, ou diretamente, se o processador te deixar definir um bearer token estático), já depois de ele próprio ter verificado o pagamento do seu lado:

```bash
pepe project webhook-secret O_TEU_SEGREDO

curl -X POST https://O_TEU_HOST/webhooks/balance/acme \
  -H "Authorization: Bearer O_TEU_SEGREDO" \
  -d '{"amount": 10}'
```

Há um único segredo para os endpoints de saldo de todos os projetos: a ideia é que fique guardado na tua própria automação ou retransmissão, e não que seja entregue a terceiros projeto a projeto. O endpoint recusa qualquer pedido (404) enquanto não houver um segredo definido; `pepe project webhook-secret --clear` volta a desligá-lo.

## Ler o consumo e exportar faturas

```bash
pepe usage                                   # todos os projetos, por mês, por projeto
pepe usage --project acme --granularity day  # um projeto, por dia
pepe usage export --project acme             # uma fatura de cliente (Markdown, ou --format csv)
pepe usage prices --refresh                  # atualiza a cache ao vivo de preços
pepe usage help                              # o percurso completo
```

O `usage export` transforma o mês de um projeto numa fatura de cliente, em Markdown ou em CSV. Um agente consegue fazer sozinho a mesma coisa com a ferramenta `export_invoice`, por isso uma tarefa mensal agendada pode exportar a fatura de cada cliente e enviá-la, usando o próprio Pepe para faturar o uso do Pepe.

No painel, a secção Usage & billing mostra tokens, custo e valor a faturar por ciclo (hora, dia, semana, mês, ano), com desagregações por projeto, modelo e agente. Os preços por modelo definem-se em Models, depois Edit; a margem de um projeto, em Projects, depois Edit.

A moeda é apenas um rótulo. Por omissão é `USD`, e muda-se definindo `"currency"` no `config.json`. Não há qualquer conversão cambial, por isso o número fica na moeda em que o teu fornecedor cota os próprios preços.

No painel, essa mesma página termina com uma tabela **Por mensagem**: uma linha por cada mensagem recebida, com as ferramentas que correu, quantas chamadas ao modelo isso levou, quanto tempo demorou e quanto custou. Clica numa linha para ver essas chamadas uma a uma. A mesma vista está disponível como `pepe usage runs`, e `pepe usage runs <id>` para uma única mensagem. Um relatório por ciclo conta chamadas ao modelo, e por isso nunca consegue mostrar este detalhe; o que encarece uma mensagem é o número de chamadas, não o número de ferramentas, porque cada iteração reenvia um contexto que o resultado da ferramenta anterior acabou de fazer crescer.

Os mesmos números também podem ser lidos por HTTP, pelo próprio sistema de faturação do cliente, com um token criado só para leitura: consulta a [API de consumo](../usage-api/). Ela desce um nível abaixo da fatura, até ao que custou uma única mensagem e às ferramentas que correu.
