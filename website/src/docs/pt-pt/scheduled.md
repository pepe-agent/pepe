---
title: Trabalho agendado
description: Execute agentes num horário recorrente e defina vigias duradouras do tipo "avisa-me quando X acontecer", movidas por um cronómetro interno que dispara a cada meio minuto, sem crontab do sistema e sem base de dados.
---

O Pepe pode trabalhar enquanto estás ausente. Isto assume duas formas, e cada uma resolve um problema diferente:

1. **Tarefas recorrentes** (crons). Uma tarefa corre um agente num horário fixo, uma e outra vez. "Todos os dias úteis às 9h, resume os alertas da madrugada." Continua a disparar até a desativares ou removeres.
2. **Vigias** ("avisa-me quando X"). Uma vigia continua a verificar uma condição e avisa-te exatamente uma vez quando ela se torna verdadeira. "Avisa-me quando a implementação terminar." E depois para sozinha.

Ambas correm dentro do próprio Pepe. Um pequeno cronómetro dispara a cada 30 segundos e aciona o que estiver na hora. Não há crontab do sistema, nem agendador externo, nem base de dados. Tudo vive no teu `~/.pepe/config.json`, e o histórico de execuções das tarefas é escrito em ficheiros de registo simples. O cronómetro só corre enquanto houver uma superfície de vida longa ativa, ou seja `pepe serve` ou um `pepe gateway`. Um comando de uso único como `pepe run` nunca o arranca, portanto jamais dispara trabalhos por conta própria.

Cada capacidade desta página pode ser conduzida de três maneiras: a linha de comandos `pepe`, o painel web (abre-o com `pepe serve`) e por conversa, em linguagem natural, quando um agente detém a ferramenta de gestão correspondente.

## Tarefas recorrentes

Uma tarefa é um prompt autossuficiente, um horário, um fuso horário e um sítio onde entregar o resultado. Quando dispara, o Pepe corre o agente sobre esse prompt numa **sessão nova, sem histórico de conversa**. Nada de qualquer conversa anterior é trazido, por isso o prompt tem de dizer tudo o que a execução precisa (o que fazer, que dados olhar, a janela de tempo).

### Criar uma tarefa pela linha de comandos

```bash
pepe cron add \
  --name "morning-brief" \
  --agent assistant \
  --prompt "Summarize any error-level log lines from the last 24 hours and list the top 3 issues." \
  --schedule "0 9 * * 1-5" \
  --timezone "America/Sao_Paulo" \
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
pepe cron list                 # every task, with its next run time
pepe cron add ...              # create a task (see above)
pepe cron run morning-brief    # force it now, print the result (a dry run)
pepe cron disable morning-brief
pepe cron enable morning-brief
pepe cron remove morning-brief
pepe cron logs morning-brief   # recent run history
```

Cada tarefa recebe um id legível derivado do nome (`morning-brief`). Se esse id já estiver ocupado, o Pepe acrescenta um número (`morning-brief-2`).

### Faz pelo painel

Corre `pepe serve` e abre a página **Scheduled**. Lista cada tarefa com a próxima hora de execução e dá-te as mesmas ações em botões: criar uma tarefa nova com um formulário, forçar uma execução agora, ativar ou desativar, editar, remover e abrir o histórico de uma tarefa no próprio sítio. Quando escreves o horário de uma tarefa, o painel consegue transformar uma frase simples como "todos os dias úteis às 9:30" na expressão cron correspondente por ti, usando um modelo configurado, e valida o resultado antes de guardar.

### Expressões de horário e fusos horários

O horário é uma expressão cron padrão de 5 campos: `minuto hora dia-do-mês mês dia-da-semana`.

```
0 9 * * 1-5     # 09:00, Monday through Friday
*/15 * * * *    # every 15 minutes
0 0 1 * *       # midnight on the 1st of each month
30 8 * * *      # 08:30 every day
```

Uma tarefa carrega o seu próprio **fuso horário nomeado**, não um desvio fixo em relação ao UTC. Isto importa porque "9h local" desloca-se em relação ao UTC duas vezes por ano por causa da hora de verão. O Pepe guarda a expressão mais um nome de fuso como `America/Sao_Paulo` ou `Europe/Berlin` e avalia o horário nesse fuso. Perto de uma mudança de hora de verão faz o mais sensato: salta para a frente na lacuna da primavera e escolhe o lado mais tardio da sobreposição do outono, de modo que um trabalho nunca dispara duas vezes nem desaparece em silêncio.

Define o teu fuso predefinido uma vez durante o `pepe setup`. As tarefas que não nomeiam o seu próprio fuso usam esse. Se nada estiver configurado, o valor de recurso é UTC.

<div class="note"><strong>Descreve o horário por palavras.</strong> Uma expressão cron é fácil de errar à mão. Tanto o formulário do painel como um agente por conversa conseguem transformar uma frase como "todos os dias úteis às 9:30" na expressão correspondente por ti. Cada expressão gerada é validada antes de ser guardada, portanto uma inválida nunca é armazenada.</div>

### Para onde vai o resultado

O destino do `deliver` decide o que acontece com a saída de uma execução:

- `telegram:<chat_id>` envia-a para essa conversa do Telegram. A mensagem leva o nome da tarefa como prefixo, para que uma conversa que recebe várias tarefas as consiga distinguir.
- `none` não a envia a lado nenhum. A execução ainda corre e continua registada no histórico. Bom para tarefas cujo único objetivo é um efeito secundário (escrever um ficheiro, chamar uma ferramenta).
- Qualquer outra coisa (incluindo `log`) escreve a saída no registo da aplicação.

Independentemente do destino, cada execução é acrescentada ao ficheiro de histórico da própria tarefa, por isso podes sempre reler o que aconteceu.

### O cronómetro por minuto e a recuperação

O agendador dispara a cada 30 segundos (abaixo do minuto de propósito, para que um pequeno desvio de relógio nunca o faça perder um minuto). Em cada disparo olha para todas as tarefas ativas e aciona as que coincidem com o minuto atual no fuso dessa tarefa. Uma salvaguarda por tarefa garante que um trabalho dispara **no máximo uma vez por minuto**, mesmo com o disparo a ser mais rápido do que isso.

Se o processo estava em baixo no momento em que uma tarefa deveria disparar, o Pepe faz uma **recuperação** limitada ao regressar. Quando volta e repara que uma janela agendada passou sem execução, dispara esse trabalho uma vez, desde que ainda esteja dentro de uma janela de tolerância (metade do período do trabalho, limitada entre 2 minutos e 2 horas). A recuperação está ancorada na janela perdida, por isso um único regresso nunca dispara duas vezes. Um trabalho que esteve em baixo muito mais tempo do que a sua janela de tolerância é simplesmente retomado na próxima janela normal, em vez de repetir uma antiga.

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

### Fá-lo por chat

Um agente pode criar e gerir as suas próprias tarefas agendadas durante uma conversa, no chat da linha de comandos ou em qualquer canal ligado, se tiver a ferramenta `schedule_task` no seu conjunto. Pede em linguagem natural:

> Todos os dias úteis às 8:30 da minha hora, verifica a página de estado e avisa-me aqui se algo estiver degradado.

O agente sabe a hora local atual (o seu system prompt está ancorado com ela), por isso "amanhã às 8:30" resolve-se para a janela certa em vez de derivar para UTC. Escreve o prompt completo e autossuficiente por ti, escolhe a expressão cron e, por predefinição, entrega o resultado de volta na mesma conversa a partir da qual perguntaste.

A ferramenta `schedule_task` suporta as mesmas ações da linha de comandos: `create`, `list`, `run` (forçar agora para pré-visualizar), `enable`, `disable`, `remove` e `history`.

#### A dupla autorização

Criar trabalho agendado por conversa é deliberadamente protegido duas vezes, porque uma tarefa corre sem supervisão mais tarde:

1. **A ferramenta tem de estar concedida ao agente.** Um agente só pode agendar algo se `schedule_task` estiver na sua lista de permissões. Agentes sem ela simplesmente não conseguem.
2. **Cada criação ainda te pergunta.** `schedule_task` é uma ferramenta com controlo, portanto, a menos que tenha sido pré-aprovada, o runtime pede-te para autorizar a chamada específica antes de ela ter efeito. Cada superfície mostra esse pedido à sua maneira nativa (botões embutidos no Telegram, um menu com as setas do teclado no terminal). Podes responder só desta vez, pelo resto da sessão, sempre (recordado no agente) ou recusar.

Assim uma tarefa nunca aparece pelas tuas costas: a capacidade é opcional, e cada tarefa concreta também é.

## Vigias

Uma vigia responde a uma pergunta diferente: não "faz isto pelo relógio", mas "fica de olho em algo e avisa-me no momento em que acontecer". Uma vigia volta a verificar uma condição num cronómetro e notifica-te **uma vez** quando ela se torna verdadeira, e depois para. É duradoura: sobrevive a um reinício e ao fecho da sessão que a criou, e responde sempre no canal a partir do qual foi criada.

### Acionadores por sonda e por agente

A parte barata de uma vigia é o **acionador**, que corre a cada intervalo. Só quando o acionador dispara é que a notificação (possivelmente cara) corre, uma vez. Há dois tipos de acionador:

- Uma **sonda** corre um comando de shell e não custa tokens por verificação. Sucesso é o código de saída 0 por predefinição, ou podes exigir que uma cadeia apareça na saída do comando. Usa uma sonda sempre que a condição for scriptável (um URL está acessível, um trabalho escreveu um ficheiro, um registo contém uma linha).
- Um acionador de **agente** volta a colocar ao agente uma pergunta de sim/não a cada intervalo, uma chamada ao modelo por verificação. Usa-o só quando decidir se a condição foi cumprida exigir juízo verdadeiro.

Como as verificações de agente custam tokens, o seu intervalo mínimo é mais alto: 300 segundos para acionadores de agente, 30 segundos para sondas. O intervalo predefinido é de 120 segundos.

### O que envia quando dispara

Quando o acionador enfim passa, uma vigia entrega uma mensagem. Essa mensagem é ou um **modelo** fixo (um texto que defines à partida, sem chamada ao modelo) ou é **composta pelo agente** na altura do disparo (uma chamada ao modelo, uma vez), para que possa incluir detalhe fresco, como um resumo do que de facto aconteceu.

### Criar uma vigia pela linha de comandos

A linha de comandos cria vigias por sonda. As vigias julgadas por agente são criadas por conversa, onde o modelo já está no ciclo.

```bash
pepe watch add "api-up" \
  --probe "curl -sf https://api.example.com/health" \
  --message "The API is back up." \
  --every 120 \
  --deliver "telegram:123456789"
```

- A descrição (`"api-up"`) torna-se o id da vigia.
- `--probe` é o comando de shell a sondar. Sem `--contains`, sucesso significa que o comando sai com 0.
- `--contains STR` em vez disso faz o sucesso significar que `STR` aparece na saída do comando.
- `--message` é o texto a enviar quando dispara. Omite-o para uma confirmação predefinida.
- `--every` é o intervalo de sondagem em segundos (mínimo 30).
- `--deliver telegram:<chat>` envia a notificação para essa conversa. Omite-o e a notificação vai para o registo da aplicação.

Gerir vigias:

```bash
pepe watch list                 # all watches, with state and check count
pepe watch pause api-up
pepe watch resume api-up
pepe watch cancel api-up
```

### Faz pelo painel

Abre a página **Watches** sob `pepe serve` para veres cada vigia com o seu estado, acionador, intervalo e quantas verificações já usou do seu orçamento. A partir daí podes pausar, retomar e cancelar uma vigia. As vigias novas são criadas pela linha de comandos ou por conversa, onde o acionador e o destino de entrega são configurados.

### Fá-lo por chat

Pede em linguagem natural e o agente cria a vigia através da sua ferramenta `watch`. Tal como `schedule_task`, a ferramenta `watch` tem de estar no conjunto do agente e passa pelo mesmo pedido de permissão em cada criação, portanto aplica-se a mesma dupla autorização.

> Avisa-me quando a implementação terminar. Verifica a cada poucos minutos.

Para uma verificação scriptável o agente configura uma sonda. Para algo que precisa de juízo configura um acionador de agente, formulando uma pergunta de sim/não que responde a cada intervalo. Também pode optar por compor a mensagem de disparo com o modelo em vez de um modelo fixo, para que a notificação transporte um resumo real em vez de uma linha enlatada. As ações da ferramenta `watch` são `create`, `list`, `pause`, `resume` e `cancel`.

Para manter as coisas limitadas, pode haver no máximo 50 vigias ativas ao mesmo tempo, e o Pepe recusa uma vigia nova cuja condição seja idêntica a uma já em execução, por isso não empilhas duplicados sem querer. Uma vigia também tem um número máximo de verificações; se a condição nunca se tornar verdadeira dentro desse orçamento, a vigia expira em silêncio em vez de sondar para sempre.

### Entrega no canal de origem

Uma vigia regista a sua **origem**, o canal e a conversa a partir dos quais foi criada, no momento da criação. Quando dispara, entrega de volta aí, mesmo depois de um reinício, seja uma conversa do Telegram, uma sessão de terminal ou WebSocket ligada, ou o registo da aplicação. Se a vigia foi criada pela API HTTP sem estado (que não tem conversa para responder), recorre ao registo.

Duas garantias tornam isto fiável:

- **No máximo uma vez.** O novo estado da vigia (normalmente "done") é guardado em disco *antes* de a entrega ser tentada. Se o processo falhar entre o disparo e a entrega, não voltará a verificar nem a disparar uma segunda vez. Só a entrega é repetida.
- **Entregar quando alcançável.** Se uma vigia dispara enquanto o seu canal está offline (uma sessão de terminal que se desligou, por exemplo), a mensagem é retida e reenviada a cada disparo até chegar. Recebes a notificação quando regressas, sem a vigia voltar a verificar.

Uma vigia passa por um pequeno conjunto de estados ao longo da sua vida: `pending` (ainda a vigiar), `paused`, `done` (disparada e entregue), `expired` (esgotou o seu orçamento de verificações) ou `cancelled`.

<div class="note"><strong>Sem base de dados, sem crontab.</strong> Tarefas e vigias são registos simples no <code>~/.pepe/config.json</code>, e o histórico de execuções das tarefas é um ficheiro JSONL por tarefa sob <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. Não há mais nada para instalar ou manter em funcionamento. Todo o agendador é um cronómetro dentro do processo que arranca quando corres <code>pepe serve</code> ou um gateway, e para quando os paras.</div>
