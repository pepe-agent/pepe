---
title: Board
description: Cartões de tarefa duráveis, com dependências, para passar trabalho entre agentes e humanos.
---

## O que é

Um board é uma fila durável e retomável de itens de trabalho: **não** é um pipeline de vendas/CRM. Um cartão é um item de trabalho, não um contacto ou um lead. Enquanto uma tarefa agendada dispara o mesmo prompt num relógio recorrente, um cartão de board é um trabalho pontual que passa por um pipeline de estados, pode depender de outros cartões terminarem primeiro, e sobrevive a uma falha ou a um reinício em vez de simplesmente se perder.

```
todo → ready → running → done | blocked → archived
```

Um cartão é promovido de `todo` para `ready` assim que todo o cartão de que depende chega a `done`. De `ready` é **reivindicado** (por um humano, um agente, ou automaticamente) e passa a `running`. Termina em `done`, ou em `blocked` com um motivo se algo o interrompeu, incluindo uma reivindicação que encravou ou uma execução que terminou sem nunca dizer que tinha concluído. Um cartão bloqueado precisa sempre de um `unblock` explícito antes de voltar a correr: nada aqui tenta de novo sozinho, porque um cartão é um turno de agente a sério, não um script.

### Criar um board pela linha de comandos

```bash
pepe board add --name "Engenharia" --project acme
```

`--auto-dispatch` liga o disparo sem supervisão: um cartão `ready` com um responsável começa sozinho assim que o board dá por ele, em vez de esperar que alguém o reivindique. Vem desligado por predefinição: vê a nota de segurança abaixo antes de o ligares. `--claim-timeout-s` controla quanto tempo uma reivindicação pode correr antes de ser tratada como encravada e bloqueada (predefinição 1800; `0` significa nunca).

```bash
pepe board card add acme/eng \
  --title "Corrigir o timeout do checkout" \
  --body "Tudo o que o responsável precisa de saber: é só isso que ele recebe, sem memória de conversa." \
  --assignee acme/suporte \
  --priority 5 \
  --depends-on c_ab12,c_cd34
```

Um cartão pode substituir o `auto_dispatch` do próprio board, nas duas direções: `--auto-dispatch` / `--no-auto-dispatch` no `card add`, ou `pepe board card auto-dispatch ID on|off|inherit` num cartão já existente. Um `claim` manual funciona sempre, independentemente disto: isto só decide se o próprio relógio do scheduler dispara o cartão sem ser pedido.

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
pepe board card unblock ID
pepe board card comment ID --text NOTA   # uma nota, sem mudar o estado
pepe board card archive ID [--force]     # --force arquiva até um cartão em execução
pepe board card unarchive ID
```

### Faz pelo painel

Corre `pepe serve` e abre a página **Board**. Escolhe um board (ou cria um) para ver os seus cartões agrupados em colunas por estado. A partir daí dá para criar um cartão, reivindicar um que esteja pronto, desbloquear um bloqueado, ou arquivar um, incluindo forçar o arquivo de algo ainda em `running`, a única ação deliberadamente **não** disponível a um agente (vê abaixo). A página atualiza ao vivo à medida que os cartões mudam, seja essa mudança vinda do painel, da linha de comandos, ou de um agente a trabalhar no board.

### Faz por conversa

Um agente gere boards e cartões com a ferramenta `board`, se ela estiver no seu conjunto de ferramentas:

> Cria um board chamado "Escalamentos de suporte" e põe lá um cartão para o problema de login que a Sara reportou, atribuído ao agente de piquete.

Quando um agente é despachado para trabalhar num cartão (um board com `auto_dispatch` a reivindicar e a correr o seu responsável), não precisa de passar o id do cartão para `complete`, `block` ou `comment`: o Pepe infere isso automaticamente a partir dessa sessão.

<div class="note"><strong>Um responsável de board com auto-dispatch precisa de <code>auto_approve</code> para <code>board</code>.</strong> Um cartão despachado por um board com auto-dispatch não tem nenhum humano por perto para aprovar seja o que for, o mesmo caso de uma tarefa agendada a correr sem supervisão. Sem <code>board</code> na lista de <code>auto_approve</code> do agente responsável, toda a chamada a <code>complete</code>/<code>block</code>/<code>comment</code> que ele fizer é negada em silêncio, e o cartão fica parado até o limite de tempo de reivindicação do board o bloquear.</div>

## Dependências e ciclos

`depends_on` aponta para outros cartões do **mesmo board** que têm de chegar a `done` primeiro: uma dependência de outro board, um id desconhecido, ou qualquer coisa que criasse um ciclo é rejeitada no momento de a adicionar. Um cartão `archived` nunca satisfaz uma dependência, só `done` satisfaz: se algo de que um cartão depende é cancelado, o cartão que espera fica visivelmente parado em `todo` em vez de ser promovido em silêncio por cima de uma decisão abandonada.

## Reivindicações sem disputa

Dois interessados (um humano a clicar em "Reivindicar" e a chamada de ferramenta de um agente, ou dois ciclos de auto-dispatch) nunca conseguem ganhar a mesma reivindicação de um cartão ao mesmo tempo. O primeiro a chegar ganha; o outro recebe um erro limpo de "não está pronto". Isto vale sem precisares de nenhum passo extra de bloqueio da tua parte: é assim que `claim` está construído.

## Auto-dispatch e o limite de tempo de reivindicação

Com `auto_dispatch` desligado (a predefinição), um cartão `ready` só espera: nada o dispara além de um `claim` explícito, vindo do painel, da linha de comandos, ou de um agente. Com ele ligado, o próprio relógio do board (a cada 30 segundos, aproximadamente) reivindica e despacha qualquer cartão `ready` que tenha um responsável, correndo esse agente numa sessão nova montada à volta do cartão. Um cartão `ready` sem responsável nunca dispara sozinho, de nenhuma forma.

Qualquer cartão específico pode substituir a definição do próprio board: forçar um cartão a disparar sozinho dentro de um board normalmente manual, ou forçar um cartão a ficar manual num board normalmente automático. Define isso na criação do cartão, muda depois pelo painel (um seletor pequeno no próprio cartão), pela linha de comandos (`card auto-dispatch ID on|off|inherit`), ou por conversa (`board set_auto_dispatch`).

`claim_timeout_s` é a rede de segurança para uma execução despachada que fica calada: se uma reivindicação sobrevive para lá dele, o cartão é bloqueado com "claim timed out" em vez de ficar reivindicado para sempre. O mesmo acontece se a sessão despachada terminar (normalmente ou a falhar) sem nunca chamar `complete` ou `block`: isso é tratado como uma violação de protocolo, não é repetido em silêncio.
