---
title: Board
description: Cards de tarefa duráveis, com dependências, para repassar trabalho entre agentes e humanos.
---

## O que é

Um board é uma fila durável e retomável de itens de trabalho: **não** é um pipeline de vendas/CRM. Um card é um item de trabalho, não um contato ou um lead. Enquanto uma tarefa agendada dispara o mesmo prompt num relógio recorrente, um card de board é um trabalho pontual que passa por um pipeline de status, pode depender de outros cards terminarem antes, e sobrevive a uma queda ou reinício em vez de simplesmente se perder.

```
todo → ready → running → done | blocked → archived
```

Um card é promovido de `todo` para `ready` assim que todo card do qual ele depende chega em `done`. De `ready` ele é **reivindicado** (por um humano, um agente, ou automaticamente) e passa para `running`. Termina em `done`, ou em `blocked` com um motivo se algo o interrompeu, incluindo uma reivindicação que travou ou uma execução que terminou sem nunca dizer que tinha concluído. Um card bloqueado sempre precisa de um `unblock` explícito antes de rodar de novo: nada aqui tenta de novo sozinho, porque um card é um turno de agente de verdade, não um script.

### Criar um board pela CLI

```bash
pepe board add --name "Engenharia" --project acme
```

`--auto-dispatch` liga o disparo sem supervisão: um card `ready` com um responsável começa sozinho assim que o board percebe, em vez de esperar alguém reivindicá-lo. Vem desligado por padrão: veja a nota de segurança abaixo antes de ligar. `--claim-timeout-s` controla quanto tempo uma reivindicação pode rodar antes de ser tratada como travada e bloqueada (padrão 1800; `0` significa nunca).

```bash
pepe board card add acme/eng \
  --title "Corrigir o timeout do checkout" \
  --body "Tudo que o responsável precisa saber: é só isso que ele recebe, sem memória de chat." \
  --assignee acme/suporte \
  --priority 5 \
  --depends-on c_ab12,c_cd34
```

Um card pode sobrescrever o `auto_dispatch` do próprio board, nas duas direções: `--auto-dispatch` / `--no-auto-dispatch` no `card add`, ou `pepe board card auto-dispatch ID on|off|inherit` num card já existente. Um `claim` manual sempre funciona independente disso: isso só decide se o próprio relógio do scheduler dispara o card sem pedir.

O conjunto completo de comandos:

```bash
pepe board list                          # todos os boards
pepe board add --name N [...]            # cria um board
pepe board remove ID [--force]           # remove (--force também apaga os cards)

pepe board card list BOARD_ID [--status S]
pepe board card show ID
pepe board card add BOARD_ID --title T [...] [--auto-dispatch|--no-auto-dispatch]
pepe board card link ID DEP_ID           # adiciona uma dependência
pepe board card force-ready ID           # pula a checagem de dependência
pepe board card auto-dispatch ID on|off|inherit  # sobrescreve o dispatch deste card
pepe board card claim ID [--as NOME]
pepe board card complete ID [--text NOTA]
pepe board card block ID --text MOTIVO
pepe board card unblock ID
pepe board card comment ID --text NOTA   # uma nota, sem mudar o status
pepe board card archive ID [--force]     # --force arquiva até um card em execução
pepe board card unarchive ID
```

### Faça pelo painel

Rode `pepe serve` e abra a página **Board**. Escolha um board (ou crie um) para ver seus cards agrupados em colunas por status. De lá dá para criar um card, reivindicar um que está pronto, desbloquear um bloqueado, ou arquivar um, incluindo forçar o arquivamento de algo ainda em `running`, a única ação deliberadamente **não** disponível para um agente (veja abaixo). A página atualiza ao vivo conforme os cards mudam, seja essa mudança vinda do painel, da CLI, ou de um agente trabalhando no board.

### Faça por chat

Um agente gerencia boards e cards com a ferramenta `board`, se ela estiver no seu conjunto de ferramentas:

> Cria um board chamado "Escalonamentos de suporte" e coloca um card nele pro bug de login que a Sarah reportou, atribuído ao agente de plantão.

Quando um agente é despachado para trabalhar em um card (um board com `auto_dispatch` reivindicando e rodando seu responsável), ele não precisa passar o id do card para `complete`, `block` ou `comment`: o Pepe infere isso automaticamente a partir daquela sessão.

<div class="note"><strong>Um responsável de board com auto-dispatch precisa de <code>auto_approve</code> para <code>board</code>.</strong> Um card despachado por um board com auto-dispatch não tem nenhum humano por perto para aprovar nada, o mesmo caso de uma tarefa agendada rodando sem supervisão. Sem <code>board</code> na lista de <code>auto_approve</code> do agente responsável, toda chamada de <code>complete</code>/<code>block</code>/<code>comment</code> que ele fizer é negada silenciosamente, e o card fica parado até o tempo limite de reivindicação do board bloqueá-lo.</div>

## Dependências e ciclos

`depends_on` aponta para outros cards do **mesmo board** que precisam chegar em `done` primeiro: uma dependência de outro board, um id desconhecido, ou qualquer coisa que criaria um ciclo é rejeitada na hora de adicionar. Um card `archived` nunca satisfaz uma dependência, só `done` satisfaz: se algo que um card espera é cancelado, o card que espera fica visivelmente parado em `todo` em vez de ser promovido silenciosamente por cima de uma decisão abandonada.

## Reivindicações são livres de disputa

Dois interessados (um humano clicando em "Reivindicar" e a chamada de ferramenta de um agente, ou dois ciclos de auto-dispatch) nunca conseguem ganhar a mesma reivindicação de um card ao mesmo tempo. O primeiro que chega ganha; o outro recebe um erro limpo de "não está pronto". Isso vale sem você precisar de nenhum passo extra de travamento: é assim que `claim` é construído.

## Auto-dispatch e o tempo limite de reivindicação

Com `auto_dispatch` desligado (o padrão), um card `ready` só espera: nada o dispara além de um `claim` explícito, vindo do painel, da CLI, ou de um agente. Com ele ligado, o próprio relógio do board (a cada 30 segundos, aproximadamente) reivindica e despacha qualquer card `ready` que tenha um responsável, rodando aquele agente numa sessão nova montada em torno do card. Um card `ready` sem responsável nunca dispara sozinho, de nenhuma forma.

Qualquer card específico pode sobrescrever a configuração do próprio board: forçar um card a disparar sozinho dentro de um board normalmente manual, ou forçar um card a ficar manual num board normalmente automático. Defina isso na criação do card, mude depois pelo painel (um seletor pequeno no próprio card), pela CLI (`card auto-dispatch ID on|off|inherit`), ou por chat (`board set_auto_dispatch`).

`claim_timeout_s` é a rede de segurança para uma execução despachada que fica muda: se uma reivindicação sobrevive além dele, o card é bloqueado com "claim timed out" em vez de ficar reivindicado para sempre. A mesma coisa acontece se a sessão despachada terminar (normalmente ou travando) sem nunca chamar `complete` ou `block`: isso é tratado como uma violação de protocolo, não é repetido silenciosamente.
