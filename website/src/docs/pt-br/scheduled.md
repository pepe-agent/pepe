---
title: Tarefas agendadas
description: Um agente que faz algo por você num horário fixo, sem ninguém no teclado. Um resumo pela manhã, uma checagem de hora em hora, entregue onde você preferir.
---

## Tarefas recorrentes

Uma tarefa agendada é um trabalho que você monta uma única vez e que, dali em diante,
passa a acontecer sozinho: "todo dia útil às 9, resume os erros da madrugada e me
manda". Por trás disso existem só quatro peças: um prompt autossuficiente, um horário,
um fuso e um destino para o resultado. No disparo, o Pepe roda o agente sobre esse
prompt dentro de uma **sessão nova, sem histórico de conversa nenhum**. Como nada de
execuções anteriores é carregado junto, o prompt precisa trazer tudo o que aquela
execução vai precisar: o que fazer, onde buscar os dados, qual janela de tempo olhar.

<div class="note">Assim que o prompt de uma tarefa passa a repetir sempre a mesma coisa, pagar por uma chamada de modelo a cada disparo vira desperdício puro. Para esse caso existe <a href="../flows/">Flows</a>: uma tarefa agendada que, em vez de um prompt, reproduz uma sequência de chamadas de ferramenta já comprovada, sem nenhuma chamada ao modelo.</div>

### Criando uma tarefa pela CLI

```bash
pepe cron add \
  --name "morning-brief" \
  --agent assistant \
  --prompt "Resuma as linhas de log de erro das últimas 24 horas e liste os 3 principais problemas." \
  --schedule "0 9 * * 1-5" \
  --timezone "America/Sao_Paulo" \
  --deliver "telegram:123456789"
```

Só `--name`, `--prompt` e `--schedule` são obrigatórios; o resto já vem com um valor padrão razoável:

| Opção | Para que serve | Padrão |
| --- | --- | --- |
| `--agent` | Quem roda o prompt | Seu agente padrão |
| `--timezone` | Fuso IANA usado para ler o horário | O fuso padrão configurado (veja abaixo) |
| `--model` | Roda esta tarefa com uma conexão de modelo específica | O modelo do próprio agente |
| `--deliver` | Destino do resultado | `none` (fica registrado, mas não é enviado a lugar nenhum) |

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

O id de cada tarefa sai do próprio nome (`morning-brief`); se já estiver em uso, o Pepe
resolve acrescentando um número (`morning-brief-2`).

### Pelo painel

Suba o `pepe serve` e abra a página **Scheduled**. Ela mostra todas as tarefas com a
próxima execução prevista e oferece as mesmas ações em forma de botão: criar uma
tarefa nova por formulário, forçar uma execução agora, ativar, desativar, editar,
remover, e abrir o histórico de uma tarefa sem sair da página. O formulário de criação
cobre tudo que a CLI cobre: agente, prompt, horário, fuso, modelo e para onde mandar o
resultado, incluindo a opção "não enviar a lugar nenhum". Ao digitar o horário, o
painel consegue converter uma frase solta como "todo dia útil às 9:30" na expressão
cron equivalente, usando um modelo configurado para isso, e valida o resultado antes
de salvar.

### Expressões de horário e fusos

O horário segue o formato cron padrão de 5 campos: `minuto hora dia-do-mês mês
dia-da-semana`.

```
0 9 * * 1-5     # 09:00, segunda a sexta
*/15 * * * *    # a cada 15 minutos
0 0 1 * *       # meia-noite no dia 1 de cada mês
30 8 * * *      # 08:30 todos os dias
```

Cada tarefa guarda o próprio **fuso nomeado**, não um deslocamento fixo de UTC, porque
"9h no horário local" se desloca em relação ao UTC duas vezes por ano com a virada do
horário de verão. O Pepe salva a expressão junto com um nome de fuso, como
`America/Sao_Paulo` ou `Europe/Berlin`, e avalia o horário dentro dessa zona. Na
própria virada, o comportamento é o esperado: no salto de primavera ele avança junto
em vez de travar, e na sobreposição de outono fica com a segunda ocorrência do
horário. Resultado: um trabalho nunca dispara em dobro nem desaparece sem explicação.

Configure seu fuso padrão uma única vez, durante o `pepe setup`. Toda tarefa que não
nomear o próprio fuso usa esse; sem nenhuma configuração, o valor de reserva é UTC.

<div class="note"><strong>Descreva o horário com suas palavras.</strong> Escrever uma expressão cron na mão é fácil de errar. Tanto o formulário do painel quanto um agente na conversa convertem uma frase como "todo dia útil às 9:30" na expressão certa por você, e toda expressão gerada passa por validação antes de ser salva, então nenhuma inválida chega a ser gravada.</div>

### Para onde o resultado vai

O destino em `deliver` decide o que acontece com a saída de cada execução:

- `telegram:<chat_id>` manda para aquele chat específico. A mensagem sai com o nome da tarefa na frente, útil quando o mesmo chat recebe várias tarefas diferentes e precisa distingui-las.
- `none` não manda para lugar nenhum; a execução acontece e fica registrada no histórico mesmo assim. Serve bem para tarefas cujo objetivo é só um efeito colateral, como escrever um arquivo ou chamar uma ferramenta.
- Qualquer outro valor, incluindo `log`, joga a saída no log da aplicação.

Independente do destino escolhido, toda execução também vai parar no arquivo de
histórico da própria tarefa, então dá sempre para voltar e conferir o que aconteceu.

### O tique de minuto a minuto e a recuperação

O agendador acorda a cada 30 segundos, de propósito abaixo de um minuto inteiro, para
que uma pequena variação de relógio nunca faça um disparo passar batido. A cada
verificação ele percorre as tarefas ativas e dispara as que batem com o minuto atual
no fuso de cada uma. Uma trava por tarefa garante que ela dispare **no máximo uma vez
por minuto**, mesmo com a verificação rodando mais rápido do que isso.

Esse relógio vive dentro do processo da aplicação, então só está de pé enquanto `pepe
serve` ou `pepe gateway` estiverem rodando, nunca durante um comando de execução
única. Cada tarefa que vence roda no seu próprio processo, então várias que caem no
mesmo minuto disparam ao mesmo tempo sem uma travar a outra. As definições em si ficam
gravadas em `~/.pepe/config.json`, dentro de `"crons"`.

Se o processo estava fora do ar bem na hora em que uma tarefa deveria ter disparado, o
Pepe faz uma **recuperação** limitada assim que volta: percebendo que uma janela
agendada passou sem execução, ele dispara aquele trabalho uma única vez, contanto que
ainda esteja dentro de uma margem de tolerância (metade do próprio período da tarefa,
sempre entre 2 minutos e 2 horas). Essa recuperação fica ancorada na janela perdida
específica, então uma única volta do processo nunca dispara o mesmo job duas vezes. Se
o processo ficou fora do ar por muito mais tempo que essa margem, a tarefa simplesmente
espera a próxima janela normal em vez de tentar repetir algo já velho.

### Uma tarefa não roda por cima de si mesma

Se a execução anterior de uma tarefa **ainda estiver em andamento** quando chega o
próximo horário, essa nova rodada é **pulada**, e o pulo fica registrado no histórico.

O motivo de pular em vez de empilhar é que uma tarefa aqui não é um script idempotente:
é **um turno de agente**. Ela custa uma chamada de modelo, produz efeitos colaterais
(uma mensagem entregue, um arquivo escrito), e todas as execuções da mesma tarefa
dividem um único workspace de agente. Um job que leva sete minutos rodando num
agendamento de cinco em cinco acabaria empilhando: duas execuções, depois três, depois
quatro, cada uma cobrada, o relatório entregue em dobro, e duas rodadas escrevendo por
cima uma da outra ao mesmo tempo. Você só ficaria sabendo pela fatura.

E isso nunca acontece em silêncio: o pulo vira uma entrada de falha no histórico,
explicando exatamente o motivo.

> ⏭️ skipped: the previous run was still going. This job takes longer than its own schedule allows.

É justamente essa entrada que importa. Sem ela, o job simplesmente pararia de
acontecer no horário certo, e o primeiro sinal de que algo mudou seria perceber que
aquilo que ele fazia deixou de ser feito.

```bash
pepe cron add --name "digest" --prompt "..." --schedule "*/5 * * * *" --overlap
```

`--overlap` (ou `"overlap": true` na configuração) libera a execução simultânea mesmo
assim, para quando a concorrência é exatamente o que você quer.

### Histórico de execuções

Todo disparo, seja pelo relógio, por um `pepe cron run` forçado, por um botão do
painel ou por um pedido no chat, acrescenta uma linha ao arquivo de histórico daquela
tarefa (`<PEPE_HOME>/data/cron_logs/<id>.jsonl`). Cada linha guarda o horário, a
origem, se deu certo e a saída, já cortada no tamanho.

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

O campo `source` de cada linha é `scheduler` quando o relógio disparou,
`manual` quando você forçou pela CLI ou pelo painel, ou `agent` quando um chat forçou.

### Pela conversa

Com a ferramenta `schedule_task` no próprio conjunto, um agente pode criar e gerenciar
as próprias tarefas agendadas durante uma conversa, seja no chat da CLI ou em qualquer
canal conectado. Basta pedir em linguagem natural:

> Todo dia útil às 8:30 no meu horário, cheque a página de status e me avise aqui se algo estiver degradado.

O agente sabe a hora local no momento (o próprio system prompt já vem com essa
informação), então "amanhã às 8:30" cai na janela certa em vez de escorregar para
UTC. Ele mesmo escreve o prompt completo e autossuficiente, escolhe a expressão cron
e, por padrão, entrega o resultado de volta no mesmo chat de onde veio o pedido.

A ferramenta `schedule_task` cobre as mesmas ações da CLI: `create`, `list`, `run`
(forçar agora, para conferir o resultado antes), `enable`, `disable`, `remove` e
`history`.

#### A dupla trava de entrada

Criar trabalho agendado pela conversa é protegido em duas camadas de propósito, porque
essa tarefa vai rodar sozinha depois, sem ninguém supervisionando:

1. **A ferramenta precisa estar liberada para o agente.** Um agente novo já nasce com `schedule_task` habilitada, como qualquer outra ferramenta; tire-a da lista dele se esse agente nunca deve poder agendar nada.
2. **Cada criação ainda passa por você.** `schedule_task` é uma ferramenta com barreira, então, a menos que já tenha sido pré-aprovada, o runtime pede sua autorização para aquela chamada específica antes de ela valer. Cada canal mostra esse pedido do seu próprio jeito nativo (botões inline no Telegram, um menu de setas no terminal), e você pode responder só por essa vez, pelo resto da sessão, sempre (guardado no próprio agente), ou simplesmente negar.

O resultado é que uma tarefa nunca aparece pelas suas costas: dá para tirar a
capacidade inteira de um agente, e mesmo quando ela existe, cada tarefa concreta ainda
depende da sua autorização em cima disso.
