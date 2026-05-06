---
title: Tarefas agendadas
description: Rode agentes em horários cron recorrentes.
---

## Tarefas recorrentes

Uma tarefa é um prompt autossuficiente, um horário, um fuso horário e um lugar para entregar o resultado. Quando dispara, o Pepe roda o agente sobre esse prompt em uma **sessão nova, sem histórico de chat**. Nada de nenhuma conversa anterior é carregado, então o prompt precisa dizer tudo o que a execução precisa (o que fazer, quais dados olhar, a janela de tempo).

### Criar uma tarefa pela CLI

```bash
pepe cron add \
  --name "morning-brief" \
  --agent assistant \
  --prompt "Resuma as linhas de log de erro das últimas 24 horas e liste os 3 principais problemas." \
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
pepe cron list                 # todas as tarefas, com a próxima execução
pepe cron add ...              # cria uma tarefa (veja acima)
pepe cron run morning-brief    # força uma execução agora e imprime o resultado
pepe cron disable morning-brief
pepe cron enable morning-brief
pepe cron remove morning-brief
pepe cron logs morning-brief   # histórico recente de execuções
```

Cada tarefa ganha um id legível derivado do nome (`morning-brief`). Se esse id já estiver em uso, o Pepe acrescenta um número (`morning-brief-2`).

### Faça pelo painel

Rode `pepe serve` e abra a página **Scheduled**. Ela lista cada tarefa com o próximo horário de execução e te dá as mesmas ações como botões: criar uma tarefa nova com um formulário, forçar uma execução agora, ativar ou desativar, editar, remover e abrir o histórico de uma tarefa ali mesmo. Quando você digita o horário de uma tarefa, o painel consegue transformar uma frase simples como "todo dia útil às 9:30" na expressão cron correspondente para você, usando um modelo configurado, e valida o resultado antes de salvar.

### Expressões de horário e fusos

O horário é uma expressão cron padrão de 5 campos: `minuto hora dia-do-mês mês dia-da-semana`.

```
0 9 * * 1-5     # 09:00, segunda a sexta
*/15 * * * *    # a cada 15 minutos
0 0 1 * *       # meia-noite no dia 1 de cada mês
30 8 * * *      # 08:30 todos os dias
```

Uma tarefa carrega o próprio **fuso horário nomeado**, não um deslocamento fixo em relação ao UTC. Isso importa porque "9h local" desliza em relação ao UTC duas vezes por ano por causa do horário de verão. O Pepe guarda a expressão mais um nome de fuso como `America/Sao_Paulo` ou `Europe/Berlin` e avalia o horário nesse fuso. Perto de uma virada de horário de verão ele faz o mais sensato: no salto do horário de verão, avança junto; na hora que se repete, escolhe a segunda ocorrência. Assim um trabalho nunca dispara duas vezes nem some em silêncio.

Defina seu fuso padrão uma vez durante o `pepe setup`. Tarefas que não nomeiam o próprio fuso usam esse. Se nada estiver configurado, o valor de reserva é UTC.

<div class="note"><strong>Descreva o horário em palavras.</strong> Uma expressão cron é fácil de errar na mão. Tanto o formulário do painel quanto um agente pela conversa conseguem transformar uma frase como "todo dia útil às 9:30" na expressão correspondente para você. Toda expressão gerada é validada antes de ser salva, então uma inválida nunca é armazenada.</div>

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

### Faça pela conversa

Um agente pode criar e gerenciar as próprias tarefas agendadas durante uma conversa, no chat da CLI ou em qualquer canal conectado, se tiver a ferramenta `schedule_task` no conjunto dele. Peça em linguagem natural:

> Todo dia útil às 8:30 no meu horário, cheque a página de status e me avise aqui se algo estiver degradado.

O agente sabe a hora local atual (o system prompt dele é ancorado com ela), então "amanhã às 8:30" resolve para a janela certa em vez de derivar para UTC. Ele escreve o prompt completo e autossuficiente para você, escolhe a expressão cron e, por padrão, entrega o resultado de volta no mesmo chat de onde você perguntou.

A ferramenta `schedule_task` suporta as mesmas ações da CLI: `create`, `list`, `run` (forçar uma execução agora, para pré-visualizar o resultado), `enable`, `disable`, `remove` e `history`.

#### O duplo aceite

Criar trabalho agendado pela conversa é deliberadamente protegido duas vezes, porque uma tarefa roda sozinha depois:

1. **A ferramenta precisa estar concedida ao agente.** Um agente só pode agendar algo se `schedule_task` estiver na lista de permissões dele. Agentes sem ela simplesmente não conseguem.
2. **Cada criação ainda pergunta a você.** `schedule_task` passa pela barreira de permissão, então, a menos que tenha sido pré-aprovada, o runtime pede que você autorize a chamada específica antes de ela valer. Cada superfície mostra esse pedido do seu jeito nativo (botões embutidos no Telegram, um menu com as setas do teclado no terminal). Você pode responder só desta vez, pelo resto da sessão, sempre (lembrado no agente) ou negar.

Assim uma tarefa nunca aparece pelas suas costas: o recurso é opcional, e cada tarefa concreta também é.
