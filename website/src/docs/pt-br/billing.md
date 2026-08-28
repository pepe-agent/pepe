---
title: Cobrança e limites
description: Meça cada chamada de modelo por projeto, precifique, aplique uma margem sobre o que você cobra, limite o gasto ou o volume de mensagens do mês, e exporte a fatura do cliente.
---

## Quanto custa uma chamada

Toda chamada de modelo é medida e atribuída ao projeto do agente que a fez, o
que permite cobrar um cliente por token. Nenhuma superfície escapa dessa
medição: o console, a API HTTP `/v1`, o WebSocket, o Telegram e todo canal via
webhook passam pelo mesmo ponto. Cada chamada vai sendo anexada a um ledger
que nunca é reescrito, guardado no mesmo pequeno arquivo SQLite embutido dos
compromissos, das vigias e dos traces, agrupado por projeto (ex.: `default`).
É essa a trilha de auditoria de tudo que é cobrado.

O **custo** é `tokens × o preço do modelo`, cotado por 1M de tokens. Um preço
se resolve em camadas, e vence a primeira que responder:

1. O **preço manual** definido na conexão do modelo.
2. Um **cache ao vivo** em `~/.pepe/data/price_book.json`, atualizado a partir
   do OpenRouter e do mapa de preços do LiteLLM.
3. Uma **semente embutida** de preços conhecidos, usada como saída offline.

Assim, um modelo conhecido já sai precificado sozinho, e você só digita um
preço quando quer sobrescrever algum ou preencher uma lacuna. Defina preços
por modelo em Models, depois Edit, no painel, ou atualize o cache ao vivo você
mesmo:

```bash
pepe usage prices --refresh
```

Os preços também se atualizam sozinhos uma vez por semana, enquanto o `serve`
ou algum gateway estiver rodando.

O **valor a cobrar** é `preço de tabela × a margem do projeto`, o
multiplicador opcional por projeto descrito mais abaixo. O que você pagou e o
que você cobra ficam sempre lado a lado, então uma margem nunca esconde o
custo real do seu próprio time.

## Assinaturas (ChatGPT Plus, Claude Max)

Uma conversa que roda num login de assinatura não custa nada por token: o mês
já foi pago adiantado, quer você mande uma mensagem ou dez mil. Mesmo assim
ela vale exatamente o mesmo para o cliente que uma conversa que rodou na API
paga, então o Pepe guarda três números em vez de dois.

| Número | O que significa |
|---|---|
| **Tabela** | `tokens × o preço do modelo`. O que esses tokens teriam custado na API, tendo custado de fato ou não. |
| **A cobrar** | `tabela × margem`. O que o cliente paga, calculado a partir do preço de tabela e **não** do que você realmente gastou. |
| **Custo** | O que você de fato pagou. Zero para os tokens que uma assinatura cobriu, mais a mensalidade fixa daquela assinatura, contada uma única vez. |

Cobrar a partir do preço de tabela é o ponto central disso tudo. Um dia a
assinatura vai vencer e o mesmo trabalho vai cair de volta na API paga, e
nesse dia a fatura do cliente não pode se mexer nem um pouco. Um preço que
segue os seus arranjos de fornecimento é um preço que você vai ter que
explicar depois.

Diga ao Pepe quanto uma assinatura custa para você, e a margem sai certa
sozinha:

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

O bloco `oauth` é escrito automaticamente pelo `pepe model login`.
`monthly_cost` é quanto aquela assinatura custa por mês. Deixe `monthly_cost`
sem definir e a mensalidade simplesmente nunca entra na conta da margem, o que
torna a margem informada um limite superior otimista, não um número errado. O
`pepe doctor` avisa exatamente isso.

Se uma chamada rodou numa assinatura, isso é decidido **no momento em que ela
é registrada**, não quando o ledger é lido depois. Troque uma conexão de um
login para uma chave de API, e os registros do mês passado continuam
significando o que sempre significaram.

## Cobrança e limites

Toda chamada de modelo é medida por projeto (veja Agentes para entender o que
é um projeto e como criar um). Além dessa medição, um projeto pode
opcionalmente carregar dois tetos mensais independentes, mais uma margem de
cobrança:

- **Teto de gasto** (`--budget`): um limite rígido na sua moeda configurada.
  Assim que o total faturável do mês corrente atinge esse valor, os agentes
  daquele projeto param de fazer novas chamadas de modelo até o teto
  resetar.
- **Teto de mensagens** (`--message-limit`): um limite rígido em mensagens
  vindas de clientes. Uma vez atingido, os agentes daquele projeto param de
  responder a novas mensagens recebidas até o reset.
- **Margem** (`--markup`): um multiplicador aplicado sobre o custo do
  provedor para chegar no valor cobrado do cliente (ex.: `1.3` = custo do
  provedor mais 30%). Sem definir, você cobra exatamente o custo do provedor.

Os três são opcionais e independentes entre si: defina qualquer um deles,
todos, ou nenhum. O projeto default carrega os mesmos tetos que qualquer
outro, definidos com `pepe project set default ...` (ou o nome que você tiver
dado a ele, caso o tenha renomeado).

### O que conta para o teto de mensagens

O teto de mensagens conta **uma mensagem do cliente, uma única vez**, não cada
chamada de modelo que é preciso fazer para respondê-la. Se um agente chama
três ferramentas antes de responder, isso ainda conta como uma mensagem
contra o teto, do mesmo jeito que conta como uma mensagem no chat. Iterações
do loop de tool-calling, execuções de cron, mensagens de agente para agente e
heartbeats nunca entram nessa conta.

Só conta mensagens vindas de superfícies voltadas ao cliente: Telegram,
WhatsApp e outros canais via webhook, o widget incorporável. Ficam de fora, de
propósito, o console `pepe chat`, o chat de teste do próprio painel e a API
HTTP, já que nesses casos é o operador usando o próprio runtime, não um
cliente mandando mensagem para ele.

Um agente específico pode ficar isento do teto de mensagens por completo, o
que é útil para algo como um agente de escalonamento sempre ativo, que nunca
deveria emudecer só porque o resto do projeto bateu o teto:

```bash
pepe agent add escalation --exempt-message-limit
```

Hoje não existe um jeito de ligar essa flag pela CLI num agente que já existe
sem mexer no resto das configurações dele, já que `agent add` substitui a
definição inteira do agente em vez de corrigir um único campo. Para isso, use
a página de edição do agente no painel.

### Configurando os tetos

```bash
pepe project set acme --budget 100
pepe project set acme --message-limit 5000
pepe project set acme --budget 100 --message-limit 5000 --markup 1.3
```

O `project set` só mexe nas flags que você passar; o resto das configurações
do projeto fica intocado. Passe `none` para limpar um teto:

```bash
pepe project set acme --budget none
```

Os mesmos campos podem ser editados na página Projects do painel.

### Resetando um teto antes da hora

Um teto reseta sozinho no início de cada mês de faturamento, mas você não
precisa esperar até lá:

```bash
pepe project reset-budget acme
pepe project reset-messages acme
```

A página Projects do painel tem os mesmos dois botões, ao lado do badge de
cada teto, com uma confirmação que mostra a contagem atual antes de resetar.

Um reset não apaga nada, só marca um ponto de corte. Gasto ou mensagens
registrados antes do reset permanecem no ledger; eles simplesmente param de
contar para o teto daí em diante. Isso importa por um motivo bem específico:
**o badge do teto de gasto e o botão de reset afetam só a contagem
operacional usada para bloquear novas chamadas de modelo.** O registro real de
faturamento do mês, o que você de fato cobraria de um cliente, vive em Usage e
sempre reflete o total verdadeiro, resetado ou não. Se você resetar o teto de
gasto de um projeto no meio do mês, o badge da página Projects vai mostrar um
número menor do que a página Usage para aquele mesmo mês; isso é esperado, não
uma inconsistência, porque as duas respondem perguntas diferentes ("esse
projeto foi limitado desde o último reset?" contra "quanto esse projeto
custou de verdade neste mês?").

## Saldo pré-pago (dinheiro real, não um teto mensal)

O teto de gasto acima reseta sozinho todo mês: é um freio, não dinheiro de
verdade. Um **saldo pré-pago** é outra coisa: fundos reais creditados (um
pagamento recebido, ou adicionado à mão), consumidos conforme o gasto
faturável de verdade acontece, recusando novas chamadas de modelo assim que
chega a zero e continuando recusado até ser recarregado. Útil para rodar o
Pepe como serviço pago: o agente de um cliente funciona até acabar o que ele
pagou, não até o calendário virar o mês.

Um projeto que nunca recebeu crédito nenhum fica totalmente inalterado: só o
teto de gasto acima se aplica a ele, exatamente como se esse saldo nem
existisse. No instante em que algo credita um projeto, um saldo passa a
existir para ele, e os dois freios valem ao mesmo tempo: tanto o teto de
gasto quanto o saldo chegando a zero param novas chamadas.

```bash
pepe project credit acme 50          # adiciona R$50 (ou a moeda que você configurou)
pepe project balance acme            # mostra o saldo atual
```

A tela de Projetos no painel mostra um selo de saldo (azul, ou vermelho quando
esgotado) ao lado do selo de teto de gasto do projeto, a partir do momento em
que ele já tenha sido creditado alguma vez.

### Creditando automaticamente a partir de um pagamento

Um webhook genérico, sem amarração a nenhum provedor específico, credita um
saldo a partir de qualquer processador de pagamento, deliberadamente sem
integrar o SDK ou o esquema de assinatura de um processador em particular.
Aponte o próprio webhook do seu processador de pagamento para ele (uma função
relay pequena, um passo no Zapier/Make, ou direto, se o processador deixar
você definir um bearer token estático) depois que o pagamento já tiver sido
verificado do lado dele:

```bash
pepe project webhook-secret SEU_SEGREDO

curl -X POST https://SEU_HOST/webhooks/balance/acme \
  -H "Authorization: Bearer SEU_SEGREDO" \
  -d '{"amount": 10}'
```

Um único segredo cobre os endpoints de saldo de todos os projetos: a ideia é
que ele fique com o seu próprio relay ou automação, não que seja entregue a
terceiros por cliente. O endpoint recusa toda requisição (404) até um segredo
ser definido; `pepe project webhook-secret --clear` desliga de novo.

## Ler o consumo e exportar faturas

```bash
pepe usage                                   # todos os projetos, por mês, por projeto
pepe usage --project acme --granularity day  # um projeto, por dia
pepe usage export --project acme             # uma fatura de cliente (Markdown, ou --format csv)
pepe usage prices --refresh                  # atualiza o cache ao vivo de preços
pepe usage help                              # o passo a passo completo
```

O `usage export` transforma o mês de um projeto numa fatura de cliente, em
Markdown ou CSV. Um agente consegue fazer isso sozinho com a ferramenta
`export_invoice`, então uma tarefa agendada mensal pode exportar a fatura de
cada cliente e enviá-la, usando o próprio Pepe para cobrar pelo uso do Pepe.

No painel, a seção Usage & billing mostra tokens, custo e valor a cobrar por
ciclo (hora, dia, semana, mês, ano), com quebras por projeto, modelo e
agente. Os preços por modelo se definem em Models, depois Edit; a margem de um
projeto, em Projects, depois Edit.

A moeda é só um rótulo. O padrão é `USD`, e você muda isso definindo
`"currency"` no `config.json`. Não existe conversão de câmbio, então o número
sai na moeda em que o seu provedor cota os próprios preços.

No painel, essa mesma página termina com uma tabela **Por mensagem**: uma
linha por mensagem recebida, com as ferramentas que ela rodou, quantas
chamadas de modelo isso levou, quanto tempo durou e quanto custou. Clique
numa linha para ver essas chamadas uma a uma. A mesma visão está disponível
como `pepe usage runs`, e `pepe usage runs <id>` para uma mensagem específica.
Um relatório por ciclo conta chamadas de modelo, então nunca consegue mostrar
esse nível de detalhe; o que encarece uma mensagem é o número de chamadas, não
o de ferramentas, porque cada iteração reenvia um contexto que o resultado da
ferramenta anterior acabou de fazer crescer.

Os mesmos números também podem ser lidos por HTTP, pelo próprio sistema de
cobrança do cliente, com um token gerado só para leitura: veja a
[API de consumo](../usage-api/). Ela desce um nível abaixo do que a fatura
mostra, até quanto custou uma única mensagem e quais ferramentas ela rodou.
