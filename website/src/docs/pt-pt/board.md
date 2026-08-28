---
title: Board
description: Uma lista de trabalho partilhada entre agentes e pessoas. Os cartões esperam a sua vez, respeitam dependências e sobrevivem a um reinício em vez de se perderem.
---

## O que é

Um board é uma lista de trabalho partilhada entre agentes e pessoas: colocas lá trabalho sob a forma de cartões, e cada cartão vai sendo apanhado, trabalhado e concluído. É uma fila de itens de trabalho durável e retomável, **não** um pipeline de vendas ou de CRM: um cartão é uma peça de trabalho, não um contacto nem um lead. Uma tarefa agendada dispara sempre o mesmo prompt num relógio recorrente; já um cartão de board é um trabalho pontual que percorre um pipeline de estados, pode depender de outros cartões terminarem primeiro, e sobrevive a uma falha ou a um reinício em vez de se perder sem mais.

```
todo → ready → running → done | blocked → archived
```

Um cartão passa de `todo` a `ready` assim que todos os cartões de que depende chegam a `done`. A partir de `ready` é **reivindicado** (por uma pessoa, por um agente, ou automaticamente) e passa a `running`. Termina em `done`, ou em `blocked` com um motivo, sempre que algo o interrompe, incluindo uma reivindicação que encravou ou uma execução que acabou sem nunca dizer que tinha ficado concluída. Um cartão bloqueado precisa sempre de um `unblock` explícito antes de voltar a correr: nada aqui tenta de novo por conta própria, porque um cartão representa um turno de agente a sério, não um script.

### Criar um board pela linha de comandos

```bash
pepe board add --name "Engenharia" --project acme
```

`--auto-dispatch` liga o disparo sem supervisão: um cartão `ready` que já tenha responsável arranca sozinho assim que o board dá por ele, em vez de esperar que alguém o reivindique. Vem desligado por omissão, e vale a pena ler a nota de segurança mais abaixo antes de o ligares. `--claim-timeout-s` controla durante quanto tempo uma reivindicação pode correr antes de passar a ser tratada como encravada e bloqueada (por omissão, 1800; `0` significa nunca).

```bash
pepe board card add acme/eng \
  --title "Corrigir o timeout do checkout" \
  --body "Tudo o que o responsável precisa: é só isto que ele recebe, sem memória de conversa nenhuma." \
  --assignee acme/suporte \
  --priority 5 \
  --depends-on c_ab12,c_cd34
```

Um cartão pode substituir o `auto_dispatch` do seu próprio board, nos dois sentidos: com `--auto-dispatch` / `--no-auto-dispatch` no `card add`, ou com `pepe board card auto-dispatch ID on|off|inherit` num cartão que já exista. Uma reivindicação manual (`claim`) funciona sempre, seja qual for esta definição; o que ela decide é apenas se o próprio relógio do scheduler dispara o cartão sem ninguém pedir.

O conjunto completo de comandos:

```bash
pepe board list                          # todos os boards
pepe board add --name N [...]            # cria um board
pepe board remove ID [--force]           # remove (--force também apaga os cartões)

pepe board card list BOARD_ID [--status S]
pepe board card show ID
pepe board card add BOARD_ID --title T [...] [--auto-dispatch|--no-auto-dispatch]
pepe board card link ID DEP_ID           # adiciona uma dependência
pepe board card force-ready ID           # salta a verificação de dependências
pepe board card auto-dispatch ID on|off|inherit  # substitui o dispatch deste cartão
pepe board card claim ID [--as NOME]
pepe board card complete ID [--text NOTA]
pepe board card block ID --text MOTIVO
pepe board card heartbeat ID [--as NOME] # reinicia o relógio de expiração de uma reivindicação em curso
pepe board card unblock ID
pepe board card comment ID --text NOTA   # uma nota, sem mudar o estado
pepe board card archive ID [--force]     # --force arquiva mesmo um cartão ainda em execução
pepe board card unarchive ID
```

### Fazer isto no painel

Corre `pepe serve` e abre a página **Board**. Escolhe um board (ou cria um) para veres os cartões agrupados em colunas, por estado. A partir daí consegues criar um cartão, reivindicar um que esteja pronto, desbloquear um que esteja bloqueado, ou arquivar um deles, incluindo forçar o arquivo de algo que ainda esteja em `running`, a única ação que fica deliberadamente **indisponível** para um agente (ver abaixo). A página atualiza-se ao vivo à medida que os cartões mudam, quer essa mudança venha do painel, da linha de comandos, ou de um agente a trabalhar no board.

### Fazer isto por chat

Um agente com a ferramenta `board` no seu conjunto de ferramentas consegue gerir boards e cartões diretamente:

> Cria um board chamado "Escalamentos de suporte" e põe lá um cartão para o problema de login que a Sara reportou, atribuído ao agente de piquete.

Quando um agente é destacado para trabalhar um cartão ele próprio (um board com `auto_dispatch` a reivindicá-lo e a correr o seu responsável), não precisa de passar o id do cartão a `complete`, `block` ou `comment`: o Pepe deduz isso sozinho a partir dessa sessão.

<div class="note"><strong>Um responsável despachado por auto-dispatch precisa de <code>auto_approve</code> para <code>board</code>.</strong> Um cartão despachado por um board com auto-dispatch não tem ninguém por perto para aprovar seja o que for, tal como acontece na execução sem supervisão de uma tarefa agendada. Sem <code>board</code> na lista <code>auto_approve</code> do agente responsável, toda a chamada que ele fizer a <code>complete</code>, <code>block</code> ou <code>comment</code> é recusada em silêncio, e o cartão fica ali parado até o tempo limite de reivindicação do board acabar por o bloquear.</div>

## Dependências e ciclos

O `depends_on` aponta para outros cartões do **mesmo board** que têm de chegar primeiro a `done`: uma dependência para outro board, um id desconhecido, ou qualquer coisa que criasse um ciclo é recusada logo no momento em que tentas adicioná-la. Um cartão `archived` nunca chega a satisfazer uma dependência, só `done` o faz: se aquilo de que um cartão dependia acaba por ser cancelado, o cartão que estava à espera fica visivelmente parado em `todo`, em vez de avançar em silêncio por cima de uma decisão que ficou abandonada.

## Reivindicações sem disputa

Dois candidatos (uma pessoa a clicar em "Reivindicar" e, ao mesmo tempo, a chamada de ferramenta de um agente, ou dois ciclos de auto-dispatch em simultâneo) nunca conseguem os dois ganhar a reivindicação do mesmo cartão. Ganha quem chegar primeiro; o outro recebe de volta um erro limpo de "não está pronto". Isto funciona assim sem precisares de acrescentar nenhum passo de bloqueio da tua parte: é simplesmente como o `claim` foi construído.

## Auto-dispatch e o tempo limite de reivindicação

Com `auto_dispatch` desligado (a predefinição), um cartão `ready` limita-se a esperar: nada o dispara a não ser um `claim` explícito, vindo do painel, da linha de comandos, ou de um agente. Com ele ligado, é o próprio relógio do board (a cada 30 segundos, mais ou menos) que reivindica e despacha qualquer cartão `ready` que tenha um responsável, correndo esse agente numa sessão nova, construída à volta do cartão. Um cartão `ready` sem responsável nunca se dispara sozinho, em nenhum dos dois casos.

Qualquer cartão pode substituir a definição do seu próprio board: forçar um único cartão a disparar-se sozinho dentro de um board que é, no resto, manual, ou forçar um cartão a ficar manual dentro de um board que é, no resto, automático. Define isto na criação do cartão, ou muda mais tarde pelo painel (um pequeno seletor no próprio cartão), pela linha de comandos (`card auto-dispatch ID on|off|inherit`), ou por chat (`board set_auto_dispatch`).

O `claim_timeout_s` é a rede de segurança para uma execução despachada que emudece: se uma reivindicação sobrevive para lá desse tempo, o cartão é bloqueado com "claim timed out" em vez de ficar reivindicado para sempre. O mesmo acontece se a sessão despachada terminar, normalmente ou a cair, sem nunca chegar a chamar `complete` ou `block`: isso é tratado como uma violação do protocolo, e nunca é repetido em silêncio.

Para um trabalho que demora mesmo mais tempo do que `claim_timeout_s`, chama `board heartbeat` de vez em quando (ou `pepe board card heartbeat ID`, a partir de fora da sessão). Isso reinicia o relógio de expiração sem mudar o estado, para que o cartão não seja bloqueado por falta de sinal de vida enquanto ainda está mesmo a ser trabalhado. É um sinal de atividade, não um registo de progresso: para as atualizações que queiras deixar no histórico, usa antes o `comment`.
