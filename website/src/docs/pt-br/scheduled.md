---
title: Trabalho agendado
description: Rode agentes em um horário recorrente e defina vigias duráveis do tipo "me avise quando X acontecer", movidos por um cronômetro interno que dispara a cada meio minuto, sem crontab do sistema e sem banco de dados.
---

O Pepe pode trabalhar enquanto você está fora. Isso tem duas formas, e cada uma resolve um problema diferente:

1. **Tarefas recorrentes** (crons). Uma tarefa roda um agente em um horário fixo, repetidamente. "Todo dia útil às 9h, resuma os alertas da madrugada." Ela continua disparando até você desativar ou remover.
2. **Vigias** ("me avise quando X"). Uma vigia fica checando uma condição e te avisa exatamente uma vez quando ela se torna verdadeira. "Me avise quando o deploy terminar." E aí ela para sozinha.

As duas rodam dentro do próprio Pepe. Um cronômetro pequeno dispara a cada 30 segundos e aciona o que estiver na hora. Não há crontab do sistema, nem agendador externo, nem banco de dados. Tudo mora no seu `~/.pepe/config.json`, e o histórico de execuções das tarefas é escrito em arquivos de log simples. O cronômetro só roda enquanto houver uma superfície de vida longa no ar, ou seja `pepe serve` ou um `pepe gateway`. Um comando de uso único como `pepe run` nunca o inicia, então ele jamais dispara trabalhos por conta própria.

Cada recurso desta página pode ser conduzido de três formas: a linha de comando `pepe`, o painel web (abra com `pepe serve`) e por chat, em linguagem natural, quando um agente tem a ferramenta de gestão correspondente.

## Tarefas recorrentes

Uma tarefa é um prompt autossuficiente, um horário, um fuso horário e um lugar para entregar o resultado. Quando dispara, o Pepe roda o agente sobre esse prompt em uma **sessão nova, sem histórico de chat**. Nada de nenhuma conversa anterior é carregado, então o prompt precisa dizer tudo o que a execução precisa (o que fazer, quais dados olhar, a janela de tempo).

### Criar uma tarefa pela CLI

```bash
pepe cron add \
  --name "morning-brief" \
  --agent assistant \
  --prompt "Summarize any error-level log lines from the last 24 hours and list the top 3 issues." \
  --schedule "0 9 * * 1-5" \
  --timezone "America/Sao_Paulo" \
  --deliver "telegram:123456789"
```

Só `--name`, `--prompt` e `--schedule` são obrigatórios. O resto tem padrões sensatos:

| Opção | O que faz | Padrão |
| --- | --- | --- |
| `--agent` | Qual agente roda o prompt | Seu agente padrão |
| `--timezone` | Fuso horário IANA em que o horário é lido | O configurado como padrão (veja abaixo) |
| `--model` | Roda esta tarefa com uma conexão de modelo específica | O modelo do próprio agente |
| `--deliver` | Para onde vai o resultado | `none` (registrado, não enviado a lugar nenhum) |

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

Cada tarefa ganha um id legível derivado do nome (`morning-brief`). Se esse id já estiver em uso, o Pepe acrescenta um número (`morning-brief-2`).

### Faça pelo painel

Rode `pepe serve` e abra a página **Scheduled**. Ela lista cada tarefa com o próximo horário de execução e te dá as mesmas ações como botões: criar uma tarefa nova com um formulário, forçar uma execução agora, ativar ou desativar, editar, remover e abrir o histórico de uma tarefa ali mesmo. Quando você digita o horário de uma tarefa, o painel consegue transformar uma frase simples como "todo dia útil às 9:30" na expressão cron correspondente para você, usando um modelo configurado, e valida o resultado antes de salvar.

### Expressões de horário e fusos

O horário é uma expressão cron padrão de 5 campos: `minuto hora dia-do-mês mês dia-da-semana`.

```
0 9 * * 1-5     # 09:00, Monday through Friday
*/15 * * * *    # every 15 minutes
0 0 1 * *       # midnight on the 1st of each month
30 8 * * *      # 08:30 every day
```

Uma tarefa carrega o próprio **fuso horário nomeado**, não um deslocamento fixo em relação ao UTC. Isso importa porque "9h local" desliza em relação ao UTC duas vezes por ano por causa do horário de verão. O Pepe guarda a expressão mais um nome de fuso como `America/Sao_Paulo` ou `Europe/Berlin` e avalia o horário nesse fuso. Perto de uma virada de horário de verão ele faz o mais sensato: pula para a frente no vão da primavera e escolhe o lado mais tarde da sobreposição do outono, de modo que um trabalho nunca dispara duas vezes nem some em silêncio.

Defina seu fuso padrão uma vez durante o `pepe setup`. Tarefas que não nomeiam o próprio fuso usam esse. Se nada estiver configurado, o valor de reserva é UTC.

<div class="note"><strong>Descreva o horário em palavras.</strong> Uma expressão cron é fácil de errar na mão. Tanto o formulário do painel quanto um agente por chat conseguem transformar uma frase como "todo dia útil às 9:30" na expressão correspondente para você. Toda expressão gerada é validada antes de ser salva, então uma inválida nunca é armazenada.</div>

### Para onde vai o resultado

O destino do `deliver` decide o que acontece com a saída de uma execução:

- `telegram:<chat_id>` envia para aquele chat do Telegram. A mensagem leva o nome da tarefa como prefixo, para que um chat que recebe várias tarefas consiga diferenciá-las.
- `none` não envia a lugar nenhum. A execução ainda roda e ainda fica registrada no histórico. Bom para tarefas cujo único objetivo é um efeito colateral (escrever um arquivo, chamar uma ferramenta).
- Qualquer outra coisa (incluindo `log`) escreve a saída no log da aplicação.

Independentemente do destino, cada execução é acrescentada ao arquivo de histórico da própria tarefa, então você sempre pode reler o que aconteceu.

### O cronômetro por minuto e a recuperação

O agendador dispara a cada 30 segundos (abaixo do minuto de propósito, para que um pequeno desvio de relógio nunca faça ele perder um minuto). A cada disparo ele olha todas as tarefas ativas e aciona as que batem com o minuto atual no fuso daquela tarefa. Uma trava por tarefa garante que um trabalho dispare **no máximo uma vez por minuto**, mesmo com o disparo sendo mais rápido que isso.

Se o processo estava fora do ar no momento em que uma tarefa deveria disparar, o Pepe faz uma **recuperação** limitada ao voltar. Quando ele volta e percebe que uma janela agendada passou sem execução, dispara aquele trabalho uma vez, desde que ainda esteja dentro de uma janela de tolerância (metade do período do trabalho, limitada entre 2 minutos e 2 horas). A recuperação é ancorada na janela perdida, então uma única volta nunca dispara duas vezes. Um trabalho que ficou fora do ar por muito mais tempo que sua janela de tolerância é simplesmente retomado na próxima janela normal, em vez de repetir uma antiga.

### Histórico de execuções

Cada disparo, seja do cronômetro, de um `pepe cron run` forçado, de um botão do painel ou de um chat, acrescenta uma linha ao arquivo de histórico da tarefa (`<PEPE_HOME>/data/cron_logs/<id>.jsonl`). Cada linha registra o horário, a origem, se teve sucesso e a saída (cortada).

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

O campo `source` de cada linha é um entre `scheduler` (o cronômetro disparou), `manual` (você forçou pela CLI ou pelo painel) ou `agent` (um chat forçou).

### Faça por chat

Um agente pode criar e gerenciar as próprias tarefas agendadas durante uma conversa, no chat da CLI ou em qualquer canal conectado, se tiver a ferramenta `schedule_task` no conjunto dele. Peça em linguagem natural:

> Todo dia útil às 8:30 no meu horário, cheque a página de status e me avise aqui se algo estiver degradado.

O agente sabe a hora local atual (o system prompt dele é ancorado com ela), então "amanhã às 8:30" resolve para a janela certa em vez de derivar para UTC. Ele escreve o prompt completo e autossuficiente para você, escolhe a expressão cron e, por padrão, entrega o resultado de volta no mesmo chat de onde você perguntou.

A ferramenta `schedule_task` suporta as mesmas ações da CLI: `create`, `list`, `run` (forçar agora para prever), `enable`, `disable`, `remove` e `history`.

#### O duplo aceite

Criar trabalho agendado pelo chat é deliberadamente protegido duas vezes, porque uma tarefa roda sozinha depois:

1. **A ferramenta precisa estar concedida ao agente.** Um agente só pode agendar algo se `schedule_task` estiver na lista de permissões dele. Agentes sem ela simplesmente não conseguem.
2. **Cada criação ainda pergunta a você.** `schedule_task` é uma ferramenta com trava, então, a menos que tenha sido pré-aprovada, o runtime pede que você autorize a chamada específica antes de ela valer. Cada superfície mostra esse pedido do seu jeito nativo (botões embutidos no Telegram, um menu com as setas do teclado no terminal). Você pode responder só desta vez, pelo resto da sessão, sempre (lembrado no agente) ou negar.

Assim uma tarefa nunca aparece pelas suas costas: o recurso é opcional, e cada tarefa concreta também é.

## Vigias

Uma vigia responde a uma pergunta diferente: não "faça isso pelo relógio", mas "fique de olho em algo e me avise no momento em que acontecer". Uma vigia recheca uma condição em um cronômetro e te notifica **uma vez** quando ela se torna verdadeira, e então para. Ela é durável: sobrevive a um reinício e ao fechamento da sessão que a criou, e sempre responde no canal em que foi criada.

### Gatilhos por sonda e por agente

A parte barata de uma vigia é o **gatilho**, que roda a cada intervalo. Só quando o gatilho dispara é que a notificação (possivelmente cara) roda, uma vez. Há dois tipos de gatilho:

- Uma **sonda** roda um comando de shell e não custa tokens por checagem. Sucesso é código de saída 0 por padrão, ou você pode exigir que uma string apareça na saída do comando. Use uma sonda sempre que a condição for scriptável (uma URL está acessível, um trabalho escreveu um arquivo, um log contém uma linha).
- Um gatilho de **agente** repergunta ao agente uma pergunta de sim/não a cada intervalo, uma chamada ao modelo por checagem. Use só quando decidir se a condição foi atingida exigir julgamento de verdade.

Como checagens de agente custam tokens, o intervalo mínimo delas é maior: 300 segundos para gatilhos de agente, 30 segundos para sondas. O intervalo padrão é de 120 segundos.

### O que ela envia quando dispara

Quando o gatilho enfim passa, uma vigia entrega uma mensagem. Essa mensagem é ou um **modelo** fixo (um texto que você define de antemão, sem chamada ao modelo) ou é **composta pelo agente** na hora do disparo (uma chamada ao modelo, uma vez), para que possa incluir detalhe fresco, como um resumo do que de fato aconteceu.

### Criar uma vigia pela CLI

A CLI cria vigias por sonda. Vigias julgadas por agente são criadas pelo chat, onde o modelo já está no laço.

```bash
pepe watch add "api-up" \
  --probe "curl -sf https://api.example.com/health" \
  --message "The API is back up." \
  --every 120 \
  --deliver "telegram:123456789"
```

- A descrição (`"api-up"`) vira o id da vigia.
- `--probe` é o comando de shell a sondar. Sem `--contains`, sucesso significa que o comando sai com 0.
- `--contains STR` em vez disso faz o sucesso significar que `STR` aparece na saída do comando.
- `--message` é o texto a enviar quando dispara. Omita para uma confirmação padrão.
- `--every` é o intervalo de sondagem em segundos (mínimo 30).
- `--deliver telegram:<chat>` envia a notificação para aquele chat. Omita e a notificação vai para o log da aplicação.

Gerenciando vigias:

```bash
pepe watch list                 # all watches, with state and check count
pepe watch pause api-up
pepe watch resume api-up
pepe watch cancel api-up
```

### Faça pelo painel

Abra a página **Watches** sob `pepe serve` para ver cada vigia com o estado, o gatilho, o intervalo e quantas checagens ela já usou do orçamento dela. Dali você pode pausar, retomar e cancelar uma vigia. Vigias novas são criadas pela CLI ou por chat, onde o gatilho e o destino de entrega são configurados.

### Faça por chat

Peça em linguagem natural e o agente cria a vigia pela ferramenta `watch` dele. Assim como `schedule_task`, a ferramenta `watch` precisa estar no conjunto do agente e passa pelo mesmo pedido de permissão a cada criação, então vale o mesmo duplo aceite.

> Me avise quando o deploy terminar. Cheque a cada poucos minutos.

Para uma checagem scriptável o agente configura uma sonda. Para algo que precisa de julgamento ele configura um gatilho de agente, formulando uma pergunta de sim/não que responde a cada intervalo. Ele também pode escolher compor a mensagem de disparo com o modelo em vez de um modelo fixo, para que a notificação carregue um resumo real em vez de uma linha enlatada. As ações da ferramenta `watch` são `create`, `list`, `pause`, `resume` e `cancel`.

Para manter as coisas limitadas, pode haver no máximo 50 vigias ativas ao mesmo tempo, e o Pepe recusa uma vigia nova cuja condição seja idêntica a uma já em execução, então você não empilha duplicatas sem querer. Uma vigia também tem um número máximo de checagens; se a condição nunca se tornar verdadeira dentro desse orçamento, a vigia expira em silêncio em vez de sondar para sempre.

### Entrega no canal de origem

Uma vigia registra a **origem**, o canal e a conversa em que foi criada, no momento da criação. Quando dispara, ela entrega de volta ali, mesmo após um reinício, seja um chat do Telegram, uma sessão de terminal ou WebSocket conectada, ou o log da aplicação. Se a vigia foi criada pela API HTTP sem estado (que não tem conversa para responder), ela recorre ao log.

Duas garantias tornam isso confiável:

- **No máximo uma vez.** O novo estado da vigia (normalmente "done") é salvo em disco *antes* de a entrega ser tentada. Se o processo quebrar entre o disparo e a entrega, ela não vai rechecar nem disparar uma segunda vez. Só a entrega é retentada.
- **Entregar quando alcançável.** Se uma vigia dispara enquanto o canal dela está offline (uma sessão de terminal que desconectou, por exemplo), a mensagem é retida e reenviada a cada disparo até chegar. Você recebe a notificação quando volta, sem a vigia rechecar.

Uma vigia passa por um pequeno conjunto de estados ao longo da vida: `pending` (ainda vigiando), `paused`, `done` (disparada e entregue), `expired` (esgotou o orçamento de checagens) ou `cancelled`.

<div class="note"><strong>Sem banco de dados, sem crontab.</strong> Tarefas e vigias são registros simples no <code>~/.pepe/config.json</code>, e o histórico de execuções das tarefas é um arquivo JSONL por tarefa sob <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. Não há mais nada para instalar ou manter rodando. Todo o agendador é um cronômetro dentro do processo que inicia quando você roda <code>pepe serve</code> ou um gateway, e para quando você os para.</div>
