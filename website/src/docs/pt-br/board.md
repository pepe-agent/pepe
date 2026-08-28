---
title: Board
description: Uma lista de trabalho compartilhada entre agentes e pessoas, onde os cards esperam a vez, respeitam dependências e sobrevivem a um reinício em vez de simplesmente se perder.
---

## O que é

Um board é uma lista de trabalho compartilhada entre agentes e pessoas: você
coloca o trabalho ali dentro em forma de cards, e cada card é pego, trabalhado
e concluído. É uma fila durável e retomável de itens de trabalho, **não** um
pipeline de vendas ou CRM: um card é um item de trabalho, não um contato nem um
lead. Enquanto uma tarefa agendada dispara o mesmo prompt num relógio
recorrente, um card de board é um trabalho pontual que atravessa um pipeline de
status, pode depender de outros cards terminarem antes, e sobrevive a uma
queda ou a um reinício em vez de simplesmente sumir.

```
todo → ready → running → done | blocked → archived
```

Um card sai de `todo` para `ready` assim que todo card do qual ele depende
chega a `done`. A partir de `ready` ele é **reivindicado** (por um humano, um
agente, ou automaticamente) e passa para `running`. Termina em `done`, ou em
`blocked` com um motivo se algo o interrompeu no caminho, incluindo uma
reivindicação que travou ou uma execução que terminou sem nunca avisar que
tinha concluído. Um card bloqueado sempre precisa de um `unblock` explícito
antes de voltar a rodar: nada aqui tenta de novo sozinho, porque um card é um
turno de agente de verdade, não um script.

### Criar um board pela CLI

```bash
pepe board add --name "Engenharia" --project acme
```

`--auto-dispatch` liga o disparo sem supervisão: um card `ready` com um
responsável começa sozinho assim que o board percebe isso, em vez de esperar
alguém reivindicá-lo. Vem desligado por padrão, e vale a pena ler a nota de
segurança mais abaixo antes de ligar. Já `--claim-timeout-s` controla quanto
tempo uma reivindicação pode rodar antes de ser tratada como travada e
bloqueada (padrão de 1800; `0` significa nunca).

```bash
pepe board card add acme/eng \
  --title "Corrigir o timeout do checkout" \
  --body "Tudo que o responsável precisa saber: é só isso que ele recebe, sem memória de chat." \
  --assignee acme/suporte \
  --priority 5 \
  --depends-on c_ab12,c_cd34
```

Um card pode sobrescrever o `auto_dispatch` do próprio board, nas duas
direções: com `--auto-dispatch` / `--no-auto-dispatch` no `card add`, ou com
`pepe board card auto-dispatch ID on|off|inherit` num card já existente. Um
`claim` manual sempre funciona independente disso; o que muda é só se o
próprio relógio do scheduler dispara o card sem ninguém pedir.

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
pepe board card heartbeat ID [--as NOME] # reinicia o relógio de expiração de um claim em execução
pepe board card unblock ID
pepe board card comment ID --text NOTA   # uma nota, sem mudar o status
pepe board card archive ID [--force]     # --force arquiva até um card em execução
pepe board card unarchive ID
```

### Faça pelo painel

Rode `pepe serve` e abra a página **Board**. Escolha um board (ou crie um) para
ver os cards agrupados em colunas por status. De lá dá para criar um card,
reivindicar um que está pronto, desbloquear um bloqueado, ou arquivar um,
incluindo forçar o arquivamento de algo ainda em `running`, a única ação
deliberadamente **não** disponível para um agente (veja abaixo). A página
atualiza ao vivo conforme os cards mudam, seja essa mudança vinda do painel,
da CLI, ou de um agente trabalhando no board.

### Faça por chat

Um agente gerencia boards e cards com a ferramenta `board`, quando ela está no
seu conjunto de ferramentas:

> Cria um board chamado "Escalonamentos de suporte" e coloca um card nele para
> o bug de login que a Sarah reportou, atribuído ao agente de plantão.

Quando um agente é despachado para trabalhar num card (um board com
`auto_dispatch` reivindicando e rodando seu responsável), ele nem precisa
passar o id do card para `complete`, `block` ou `comment`: o Pepe deduz isso
sozinho a partir daquela sessão.

<div class="note"><strong>Um responsável de board com auto-dispatch precisa de <code>auto_approve</code> para <code>board</code>.</strong> Um card despachado por um board com auto-dispatch não tem nenhum humano por perto para aprovar nada, o mesmo cenário de uma tarefa agendada rodando sem supervisão. Sem <code>board</code> na lista de <code>auto_approve</code> do agente responsável, toda chamada de <code>complete</code>/<code>block</code>/<code>comment</code> que ele fizer é negada em silêncio, e o card fica parado até o tempo limite de reivindicação do board acabar bloqueando ele.</div>

## Dependências e ciclos

`depends_on` aponta para outros cards do **mesmo board** que precisam chegar a
`done` primeiro: uma dependência de outro board, um id desconhecido, ou
qualquer coisa que fecharia um ciclo é rejeitada já na hora de adicionar. Um
card `archived` nunca satisfaz uma dependência, só `done` satisfaz isso: se
algo que um card espera acaba sendo cancelado, o card que espera fica
visivelmente parado em `todo`, em vez de ser promovido em silêncio por cima de
uma decisão abandonada.

## Reivindicações não têm disputa

Dois interessados (um humano clicando em "Reivindicar" e a chamada de
ferramenta de um agente, ou dois ciclos de auto-dispatch) jamais conseguem
ganhar a mesma reivindicação de um card ao mesmo tempo. Quem chega primeiro
ganha; o outro recebe um erro limpo de "não está pronto". Isso vale sem você
precisar de nenhum passo extra de travamento, porque é assim que o `claim` foi
construído desde a base.

## Auto-dispatch e o tempo limite de reivindicação

Com `auto_dispatch` desligado (o padrão), um card `ready` só fica esperando:
nada o dispara além de um `claim` explícito, vindo do painel, da CLI, ou de um
agente. Com ele ligado, o próprio relógio do board (a cada 30 segundos,
aproximadamente) reivindica e despacha qualquer card `ready` que tenha um
responsável, rodando aquele agente numa sessão nova montada em torno do card.
Um card `ready` sem responsável nunca dispara sozinho, de nenhum jeito.

Qualquer card específico pode sobrescrever a configuração do próprio board:
forçar um card a disparar sozinho dentro de um board normalmente manual, ou
forçar um card a ficar manual dentro de um board normalmente automático.
Defina isso já na criação do card, ou mude depois pelo painel (um seletor
pequeno no próprio card), pela CLI (`card auto-dispatch ID on|off|inherit`), ou
pela conversa (`board set_auto_dispatch`).

`claim_timeout_s` funciona como a rede de segurança para uma execução
despachada que fica muda: se uma reivindicação ultrapassa esse tempo, o card é
bloqueado com "claim timed out" em vez de ficar reivindicado para sempre. A
mesma coisa acontece se a sessão despachada terminar, normalmente ou travando,
sem nunca chamar `complete` ou `block`: isso é tratado como uma violação de
protocolo, e não é repetido em silêncio.

Para um trabalho que genuinamente demora mais que `claim_timeout_s`, chame
`board heartbeat` periodicamente (ou `pepe board card heartbeat ID` de fora
da sessão). Isso reinicia o relógio de expiração sem mudar o status, então o
card não acaba bloqueado por inatividade enquanto ainda está sendo trabalhado
de verdade. É um sinal de que o trabalho segue vivo, não um registro de
progresso: para atualizações que você quer deixar no histórico, use
`comment`.
