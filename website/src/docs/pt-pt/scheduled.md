---
title: Tarefas agendadas
description: Um agente que faz algo por ti a horas marcadas, sem ninguém ao teclado, um resumo matinal, uma verificação de hora a hora, entregue onde tu escolheres.
---

## Tarefas recorrentes

Uma tarefa agendada entrega-se uma vez a um agente e passa a acontecer sozinha dali
para a frente: "todos os dias úteis às 9, resume os erros da noite e manda-mos". Por
baixo do capô é um prompt autossuficiente, um horário, um fuso e um destino para o
resultado. Quando dispara, o Pepe corre o agente sobre esse prompt numa **sessão nova,
sem histórico nenhum de conversa**. Como nada de conversas anteriores entra ali, o
prompt tem de trazer tudo o que a execução vai precisar, o que fazer, que dados olhar,
qual a janela de tempo.

<div class="note">Assim que o prompt de uma tarefa passa a fazer sempre exatamente a mesma coisa, gastar uma chamada real ao modelo em cada disparo é puro desperdício. Vê <a href="../flows/">Flows</a> para uma tarefa agendada que reproduz uma sequência exata e já comprovada de chamadas de ferramenta em vez de correr um prompt, sem qualquer chamada ao modelo.</div>

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

Só `--name`, `--prompt` e `--schedule` são obrigatórios; o resto tem predefinições
sensatas:

| Opção | O que faz | Predefinição |
| --- | --- | --- |
| `--agent` | Que agente corre o prompt | O teu agente predefinido |
| `--timezone` | Fuso horário IANA em que o horário é interpretado | O predefinido configurado (ver abaixo) |
| `--model` | Correr esta tarefa com uma ligação de modelo específica | O modelo do próprio agente |
| `--deliver` | Para onde vai o resultado | `none` (fica registado, sem envio) |

O conjunto completo de comandos:

```bash
pepe cron list                 # todas as tarefas, com a próxima execução
pepe cron add ...              # cria uma tarefa (ver acima)
pepe cron run morning-brief    # força já a execução e mostra o resultado
pepe cron disable morning-brief
pepe cron enable morning-brief
pepe cron remove morning-brief
pepe cron logs morning-brief   # histórico recente de execuções
```

Cada tarefa ganha um id legível, derivado do nome (`morning-brief`); se já estiver
ocupado, o Pepe acrescenta um número (`morning-brief-2`).

### Ou faz isto no painel

Corre `pepe serve` e abre a página **Scheduled**. Ali vês cada tarefa com a hora da
próxima execução, e tens as mesmas ações em botões: criar uma tarefa nova por
formulário, forçar uma execução, ativar, desativar, editar, remover, e abrir logo ali
o histórico de uma tarefa. O formulário de criação cobre tudo o que a linha de
comandos cobre, agente, prompt, horário, fuso, modelo e destino do resultado,
incluindo a opção "Não enviar para lado nenhum". Ao escreveres o horário de uma
tarefa, o painel consegue transformar uma frase solta como "todos os dias úteis às
9:30" na expressão cron correspondente, com a ajuda de um modelo configurado, e ainda
valida o resultado antes de guardar.

### Expressões de horário e fusos horários

O horário segue uma expressão cron padrão de 5 campos: `minuto hora dia-do-mês mês
dia-da-semana`.

```
0 9 * * 1-5     # 09:00, segunda a sexta
*/15 * * * *    # a cada 15 minutos
0 0 1 * *       # meia-noite no dia 1 de cada mês
30 8 * * *      # 08:30 todos os dias
```

Uma tarefa transporta o seu próprio **fuso horário nomeado**, não um desvio fixo face
ao UTC, e isto importa porque "9h local" desliza em relação ao UTC duas vezes por ano
por causa da hora de verão. O Pepe guarda a expressão junto com um nome de fuso, como
`Europe/Lisbon` ou `Europe/Berlin`, e avalia o horário nesse fuso. Perto de uma
mudança de hora, faz a coisa sensata: salta para a frente sobre a lacuna da
primavera e escolhe o lado mais tardio da sobreposição do outono, de modo que um
trabalho nunca dispara a dobrar nem desaparece em silêncio.

Define o teu fuso predefinido uma única vez durante o `pepe setup`; as tarefas que não
nomeiam o seu próprio fuso ficam com esse. Sem nada configurado, o valor de recurso é
UTC.

<div class="note"><strong>Descreve o horário por palavras.</strong> Escrever uma expressão cron à mão é fácil de errar. Tanto o formulário do painel como um agente em conversa conseguem transformar uma frase como "todos os dias úteis às 9:30" na expressão correspondente. E toda expressão gerada é validada antes de ser guardada, por isso nenhuma inválida chega a ficar armazenada.</div>

### Para onde vai o resultado

O destino em `deliver` decide o que acontece à saída de uma execução:

- `telegram:<chat_id>` envia-a para essa conversa do Telegram, com o nome da tarefa
  como prefixo, para que uma conversa que recebe várias tarefas consiga distingui-las.
- `none` não envia a lado nenhum: a execução corre na mesma e fica registada no
  histórico. Serve bem para tarefas cujo único propósito é um efeito colateral, como
  escrever um ficheiro ou chamar uma ferramenta.
- Qualquer outro valor, incluindo `log`, escreve a saída no registo da aplicação.

Seja qual for o destino, cada execução acaba sempre acrescentada ao ficheiro de
histórico da própria tarefa, por isso consegues sempre voltar atrás e ver o que
aconteceu.

### O cronómetro por minuto e a recuperação

O agendador verifica a cada 30 segundos, de propósito abaixo do minuto, para que um
pequeno desvio de relógio nunca lhe faça saltar um minuto inteiro. Em cada verificação
olha para todas as tarefas ativas e dispara as que coincidem com o minuto atual, no
fuso de cada uma. Uma salvaguarda por tarefa garante que um trabalho dispara **no
máximo uma vez por minuto**, mesmo com a verificação a correr mais depressa do que
isso.

Este cronómetro vive dentro do próprio processo da aplicação, por isso só está ativo
enquanto o `pepe serve` ou o `pepe gateway` estiver de pé, nunca num comando de
execução única. Cada tarefa cuja hora chegou corre no seu próprio processo, de modo
que várias tarefas a calhar no mesmo minuto disparam ao mesmo tempo, sem uma lenta
bloquear as outras. As definições das próprias tarefas ficam guardadas em
`~/.pepe/config.json`, sob a chave `"crons"`.

Se o processo estava em baixo no momento em que uma tarefa deveria ter disparado, o
Pepe faz, ao voltar, uma **recuperação** limitada: repara que uma janela agendada
passou sem execução e dispara esse trabalho uma vez, desde que ainda caiba dentro de
uma margem de tolerância (metade do período do trabalho, entre 2 minutos e 2 horas no
mínimo e no máximo). Essa recuperação fica ancorada à janela perdida, de modo que um
único regresso nunca dispara duas vezes. Já um trabalho que ficou em baixo muito mais
tempo do que a sua margem simplesmente retoma na próxima janela normal, sem tentar
repetir uma que já ficou velha.

### Uma tarefa não corre por cima de si mesma

Quando a execução anterior de uma tarefa **ainda está a decorrer** na hora da
seguinte, essa execução é **saltada**, e o salto fica escrito no histórico.

Ela é saltada em vez de se acumular porque uma tarefa aqui não é um script
idempotente, é **um turno de agente**: custa uma chamada ao modelo, tem efeitos
colaterais (uma mensagem entregue, um ficheiro escrito) e todas as execuções da mesma
tarefa partilham o mesmo espaço de trabalho. Um trabalho que demora sete minutos num
agendamento de cinco iria acumular: primeiro duas execuções, depois três, depois
quatro, cada uma faturada, o relatório entregue a dobrar, e duas execuções a
escreverem-se uma por cima da outra. Só darias por isso ao ver a fatura.

E nunca é saltada em silêncio: fica registada como uma entrada de falha no histórico,
com a explicação do que correu mal:

> ⏭️ skipped: the previous run was still going. This job takes longer than its own schedule allows.

Essa entrada é precisamente o ponto todo. Sem ela, o trabalho simplesmente deixaria de
acontecer à hora certa, e o primeiro sinal de que algo estava errado seria dares por
falta do que ele fazia.

```bash
pepe cron add --name "digest" --prompt "..." --schedule "*/5 * * * *" --overlap
```

Para uma tarefa em que a concorrência é mesmo o que queres, `--overlap` (ou
`"overlap": true` na configuração) deixa-a correr à mesma.

### Histórico de execuções

Cada disparo, venha do temporizador, de um `pepe cron run` forçado, de um botão do
painel ou de uma conversa, acrescenta uma linha ao ficheiro de histórico dessa tarefa
(`<PEPE_HOME>/data/cron_logs/<id>.jsonl`). Cada linha regista a data e hora, a
origem, se teve sucesso, e a saída, já cortada.

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

O campo `source` de cada linha vem sempre de um destes três: `scheduler` (foi o
temporizador a disparar), `manual` (forçaste-o pela linha de comandos ou pelo painel)
ou `agent` (uma conversa forçou-o).

### Ou faz isto pela conversa

Um agente pode criar e gerir as suas próprias tarefas agendadas durante uma conversa,
no chat da linha de comandos ou em qualquer canal ligado, desde que tenha a ferramenta
`schedule_task` no seu conjunto. Basta pedir em linguagem simples:

> Todos os dias úteis às 8:30 da minha hora, verifica a página de estado e avisa-me
> aqui se algo estiver degradado.

O agente conhece a hora local atual, porque o próprio system prompt já vem ancorado
com ela, e por isso "amanhã às 8:30" resolve-se para a janela certa em vez de derivar
para UTC. Escreve por ti o prompt completo e autossuficiente, escolhe a expressão cron
e, por predefinição, entrega o resultado de volta à mesma conversa de onde partiu o
pedido.

A ferramenta `schedule_task` suporta as mesmas ações da linha de comandos: `create`,
`list`, `run` (força já, para pré-visualizar), `enable`, `disable`, `remove` e
`history`.

#### A dupla autorização

Criar trabalho agendado a partir de uma conversa é protegido de propósito duas vezes,
precisamente porque a tarefa vai correr mais tarde sem ninguém a vigiar:

1. **A ferramenta tem de estar na lista de permissões do agente.** Um agente novo já
   nasce com `schedule_task` como qualquer outra ferramenta; retira-a da lista se esse
   agente nunca dever ter poder para agendar nada.
2. **Cada criação continua a perguntar-te.** O `schedule_task` é uma ferramenta com
   barreira, por isso, a menos que já esteja pré-aprovada, o runtime pede-te
   autorização para aquela chamada concreta antes de ela produzir efeito. Cada
   superfície mostra esse pedido à sua maneira nativa, botões embutidos no Telegram,
   um menu de setas no terminal, e podes responder só desta vez, pelo resto da sessão,
   sempre (fica gravado no agente), ou recusar.

Assim, uma tarefa nunca aparece pelas tuas costas: a capacidade pode ser retirada por
agente, e cada tarefa concreta continua a precisar da tua autorização por cima disso.
