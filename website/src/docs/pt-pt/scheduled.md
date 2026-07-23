---
title: Tarefas agendadas
description: Corre agentes em horários cron recorrentes.
---

## Tarefas recorrentes

Uma tarefa é um prompt autossuficiente, um horário, um fuso horário e um sítio onde entregar o resultado. Quando dispara, o Pepe corre o agente sobre esse prompt numa **sessão nova, sem histórico de conversa**. Nada de qualquer conversa anterior é trazido, por isso o prompt tem de dizer tudo o que a execução precisa (o que fazer, que dados olhar, a janela de tempo).

<div class="note">Quando o prompt de uma tarefa passa a fazer sempre exatamente a mesma coisa, uma chamada real ao modelo em cada execução é puro desperdício. Veja <a href="../flows/">Flows</a> para uma tarefa agendada que reproduz uma sequência exata e comprovada de chamadas de ferramenta em vez de um prompt - sem nenhuma chamada ao modelo.</div>

### Criar uma tarefa pela linha de comandos

```bash
pepe cron add \
  --name "morning-brief" \
  --agent assistant \
  --prompt "Resume as linhas de log de erro das últimas 24 horas e lista os 3 principais problemas." \
  --schedule "0 9 * * 1-5" \
  --timezone "Europe/Lisbon" \
  --deliver "telegram:123456789"
```

Apenas `--name`, `--prompt` e `--schedule` são obrigatórios. O resto assume predefinições sensatas:

| Opção | O que faz | Predefinição |
| --- | --- | --- |
| `--agent` | Que agente corre o prompt | O teu agente predefinido |
| `--timezone` | Fuso horário IANA em que o horário é lido | O configurado por predefinição (ver abaixo) |
| `--model` | Corre esta tarefa com uma ligação de modelo específica | O modelo do próprio agente |
| `--deliver` | Para onde vai o resultado | `none` (registado, não enviado a lado nenhum) |

O conjunto completo de comandos:

```bash
pepe cron list                 # todas as tarefas, com a próxima execução
pepe cron add ...              # cria uma tarefa (ver acima)
pepe cron run morning-brief    # força uma execução agora e imprime o resultado
pepe cron disable morning-brief
pepe cron enable morning-brief
pepe cron remove morning-brief
pepe cron logs morning-brief   # histórico recente de execuções
```

Cada tarefa recebe um id legível derivado do nome (`morning-brief`). Se esse id já estiver ocupado, o Pepe acrescenta um número (`morning-brief-2`).

### Faz pelo painel

Corre `pepe serve` e abre a página **Scheduled**. Lista cada tarefa com a próxima hora de execução e dá-te as mesmas ações em botões: criar uma tarefa nova com um formulário, forçar uma execução agora, ativar ou desativar, editar, remover e abrir o histórico de uma tarefa no próprio sítio. O formulário de criação cobre tudo o que a linha de comandos faz: o agente, o prompt, o horário, o fuso horário, o modelo e para onde entregar o resultado, incluindo a opção "Não enviar para lado nenhum". Quando escreves o horário de uma tarefa, o painel consegue transformar uma frase simples como "todos os dias úteis às 9:30" na expressão cron correspondente por ti, usando um modelo configurado, e valida o resultado antes de guardar.

### Expressões de horário e fusos horários

O horário é uma expressão cron padrão de 5 campos: `minuto hora dia-do-mês mês dia-da-semana`.

```
0 9 * * 1-5     # 09:00, segunda a sexta
*/15 * * * *    # a cada 15 minutos
0 0 1 * *       # meia-noite no dia 1 de cada mês
30 8 * * *      # 08:30 todos os dias
```

Uma tarefa carrega o seu próprio **fuso horário nomeado**, não um desvio fixo em relação ao UTC. Isto importa porque "9h local" desloca-se em relação ao UTC duas vezes por ano por causa da hora de verão. O Pepe guarda a expressão mais um nome de fuso como `Europe/Lisbon` ou `Europe/Berlin` e avalia o horário nesse fuso. Perto de uma mudança de hora de verão faz o mais sensato: salta para a frente na lacuna da primavera e escolhe o lado mais tardio da sobreposição do outono, de modo que um trabalho nunca dispara duas vezes nem desaparece em silêncio.

Define o teu fuso predefinido uma vez durante o `pepe setup`. As tarefas que não nomeiam o seu próprio fuso usam esse. Se nada estiver configurado, o fallback é UTC.

<div class="note"><strong>Descreve o horário por palavras.</strong> Uma expressão cron é fácil de errar à mão. Tanto o formulário do painel como um agente por conversa conseguem transformar uma frase como "todos os dias úteis às 9:30" na expressão correspondente por ti. Cada expressão gerada é validada antes de ser guardada, portanto uma inválida nunca é armazenada.</div>

### Para onde vai o resultado

O destino do `deliver` decide o que acontece com a saída de uma execução:

- `telegram:<chat_id>` envia-a para essa conversa do Telegram. A mensagem leva o nome da tarefa como prefixo, para que uma conversa que recebe várias tarefas as consiga distinguir.
- `none` não a envia a lado nenhum. A execução ainda corre e continua registada no histórico. Bom para tarefas cujo único objetivo é um efeito secundário (escrever um ficheiro, chamar uma ferramenta).
- Qualquer outra coisa (incluindo `log`) escreve a saída no registo da aplicação.

Independentemente do destino, cada execução é acrescentada ao ficheiro de histórico da própria tarefa, por isso podes sempre reler o que aconteceu.

### O cronómetro por minuto e a recuperação

O agendador dispara a cada 30 segundos (abaixo do minuto de propósito, para que um pequeno desvio de relógio nunca o faça perder um minuto). Em cada disparo olha para todas as tarefas ativas e aciona as que coincidem com o minuto atual no fuso dessa tarefa. Uma salvaguarda por tarefa garante que um trabalho dispara **no máximo uma vez por minuto**, mesmo com o disparo a ser mais rápido do que isso.

O cronómetro vive dentro do processo da aplicação, por isso só corre enquanto o `pepe serve` ou o `pepe gateway` estiver de pé, e nunca durante um comando de execução única. Cada tarefa cuja hora chegou corre no seu próprio processo, por isso várias tarefas que caiam no mesmo minuto disparam em simultâneo, e uma tarefa lenta nunca bloqueia outra. As definições das tarefas ficam guardadas em `~/.pepe/config.json`, sob `"crons"`.

Se o processo estava em baixo no momento em que uma tarefa deveria disparar, o Pepe faz uma **recuperação** limitada ao regressar. Quando volta e repara que uma janela agendada passou sem execução, dispara esse trabalho uma vez, desde que ainda esteja dentro de uma janela de tolerância (metade do período do trabalho, limitada entre 2 minutos e 2 horas). A recuperação está ancorada na janela perdida, por isso um único regresso nunca dispara duas vezes. Um trabalho que esteve em baixo muito mais tempo do que a sua janela de tolerância é simplesmente retomado na próxima janela normal, em vez de repetir uma antiga.

### Uma tarefa não corre por cima de si mesma

Uma tarefa cuja execução anterior **ainda está a correr** quando chega a hora seguinte é **saltada**, e o salto é escrito no histórico dela.

É saltada em vez de acumulada porque uma tarefa aqui não é um script idempotente, é **um turno de agente**. Custa uma chamada ao modelo, tem efeitos colaterais (uma mensagem entregue, um ficheiro escrito), e cada execução da mesma tarefa partilha um único espaço de trabalho do agente. Um trabalho que demora sete minutos num agendamento de cinco acumularia: duas execuções, depois três, depois quatro, cada uma faturada, o relatório entregue duas vezes, e duas execuções a escrever uma por cima da outra. Descobria-o pela fatura.

E nunca é saltada em silêncio. O salto fica como uma entrada de falha no histórico, e diz o que está errado:

> ⏭️ skipped: the previous run was still going. This job takes longer than its own schedule allows.

Essa entrada é o ponto. Sem ela, o trabalho deixaria simplesmente de acontecer, à hora certa, e o primeiro sinal seria que aquilo que fazia tinha deixado de ser feito.

```bash
pepe cron add --name "digest" --prompt "..." --schedule "*/5 * * * *" --overlap
```

O `--overlap` (ou `"overlap": true` na configuração) corre-a à mesma, para a tarefa em que a concorrência é mesmo o que quer.

### Histórico de execuções

Cada disparo, seja do cronómetro, de um `pepe cron run` forçado, de um botão do painel ou de uma conversa, acrescenta uma linha ao ficheiro de histórico da tarefa (`<PEPE_HOME>/data/cron_logs/<id>.jsonl`). Cada linha regista a data e hora, a origem, se teve sucesso e a saída (cortada).

```bash
pepe cron logs morning-brief
```

```
✦ Runs of morning-brief

✅ 2026-07-06 09:00 · scheduler
   3 issues overnight. Top: DB connection pool exhausted (x42), ...

⚠️ 2026-07-05 09:00 · scheduler
   error: :timeout
```

O campo `source` de cada linha é um de entre `scheduler` (o cronómetro disparou), `manual` (forçaste-o pela linha de comandos ou pelo painel) ou `agent` (uma conversa forçou-o).

### Fá-lo pela conversa

Um agente pode criar e gerir as suas próprias tarefas agendadas durante uma conversa, no chat da linha de comandos ou em qualquer canal ligado, se tiver a ferramenta `schedule_task` no seu conjunto. Pede em linguagem natural:

> Todos os dias úteis às 8:30 da minha hora, verifica a página de estado e avisa-me aqui se algo estiver degradado.

O agente sabe a hora local atual (o seu system prompt está ancorado com ela), por isso "amanhã às 8:30" resolve-se para a janela certa em vez de derivar para UTC. Escreve o prompt completo e autossuficiente por ti, escolhe a expressão cron e, por predefinição, entrega o resultado de volta na mesma conversa a partir da qual perguntaste.

A ferramenta `schedule_task` suporta as mesmas ações da linha de comandos: `create`, `list`, `run` (forçar agora para pré-visualizar), `enable`, `disable`, `remove` e `history`.

#### A dupla autorização

Criar trabalho agendado por conversa é deliberadamente protegido duas vezes, porque uma tarefa corre sem supervisão mais tarde:

1. **A ferramenta tem de estar concedida ao agente.** Um agente só pode agendar algo se `schedule_task` estiver na sua lista de permissões. Agentes sem ela simplesmente não conseguem.
2. **Cada criação ainda te pergunta.** `schedule_task` é uma ferramenta com controlo, portanto, a menos que tenha sido pré-aprovada, o runtime pede-te para autorizar a chamada específica antes de ela ter efeito. Cada superfície mostra esse pedido à sua maneira nativa (botões embutidos no Telegram, um menu com as setas do teclado no terminal). Podes responder só desta vez, pelo resto da sessão, sempre (recordado no agente) ou recusar.

Assim uma tarefa nunca aparece pelas tuas costas: a capacidade é opcional, e cada tarefa concreta também é.
