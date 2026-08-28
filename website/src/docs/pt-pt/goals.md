---
title: Objetivos
description: Faz um agente correr atrás de um resultado, avaliado por um revisor independente, até estar mesmo concluído.
---

## Pedir uma coisa vs. perseguir um objetivo

Um prompt normal só te compra **um turno**: o agente responde e, a partir
daí, és tu quem decide se ficou bem, quem pede o acerto e quem repete o
processo. Isso deixa-te dentro do ciclo como aprovador e como inspetor de
qualidade ao mesmo tempo, e o trabalho só avança enquanto estiveres sentado
ao teclado.

Um **objetivo** já te compra um **resultado**. Defines o que "concluído"
quer dizer, e o Pepe continua a trabalhar até um revisor independente
concordar que lá chegou, ou até esgotarem-se as tentativas.

A diferença está em quem faz a verificação. Num turno normal, é o próprio
agente quem decide sozinho que terminou, exatamente a avaliação em que não
dá para confiar. Num objetivo, é uma **chamada separada ao modelo** que
avalia o resultado face ao critério que definiste (o padrão de critérios
mais passos de avaliação, no formato conhecido como LLM-as-a-Judge).

## Correr um objetivo

```bash
pepe goal "OBJETIVO" --criteria "como se sabe que está concluído" \
  [--max-attempts 3] [--judge MODELO] [--agent NOME]
```

Um exemplo real:

```bash
pepe goal "limpar a lista de clientes em ~/dados/clientes.csv" \
  --criteria "sem e-mails duplicados, e todas as linhas com um telefone válido" \
  --max-attempts 4
```

O Pepe vai imprimindo cada tentativa junto com o veredito do revisor:

```
── attempt 1/4 ──
[-> read_file clientes.csv]
[✓ read_file]
...
↻ reviewer: 3 linhas continuam com a coluna de telefone vazia

── attempt 2/4 ──
...
✅ reviewer: já não há e-mails duplicados e todas as linhas têm telefone

✅ Goal met after 2 attempt(s).
```

A partir do painel, dispara-se o mesmo a partir de qualquer conversa:

```
/goal limpar a lista de clientes | sem e-mails duplicados, todas as linhas com telefone válido
```

O painel por cima da conversa passa então a mostrar o critério, a contagem
de tentativas e o último veredito do revisor, atualizados enquanto o agente
trabalha.

## Como o revisor mantém a independência

O revisor faz uma chamada nova, de **contexto limpo**: nunca vê a conversa
de trabalho, só o teu critério e o resultado final. Assim avalia o
artefacto e não o raciocínio que o produziu, e nenhum agente confiante e
errado consegue convencê-lo a aprovar.

Por omissão, o revisor usa a mesma ligação de modelo do próprio agente.
Passando `--judge`, dás-lhe um modelo **diferente**, o que é a configuração
mais robusta: um revisor independente é tanto mais independente quanto
menos for o mesmo modelo a corrigir o seu próprio trabalho de casa.

```bash
pepe goal "..." --criteria "..." --judge gpt-5-review
```

Se a resposta do revisor vier ilegível, o Pepe conta isso como **não
atingido**. Deixar passar um veredito que não se percebe abriria a porta a
um mau resultado, e é precisamente isso que este ciclo existe para evitar.

## O limite de tentativas

Este limite é **obrigatório** (3 por omissão, 10 no máximo). Um critério
que o agente nunca vai conseguir cumprir tem de custar um número finito de
tentativas, não correr indefinidamente. Ao chegar ao limite, o Pepe para,
marca o objetivo como `blocked` e diz-te o que ainda faltava:

```
🛑 Gave up at the attempt cap. Still missing: 3 linhas continuam com a coluna de telefone vazia
```

Essa mensagem, por si só, já ajuda: normalmente aponta ou para um critério
impossível de cumprir, ou para um obstáculo real que vale a pena olhares tu
próprio.

## Escrever um critério que funcione

O critério é a funcionalidade toda. Um critério vago transforma o revisor
num cara ou coroa, e o ciclo nunca chega a lado nenhum.

- **Bom:** "sem e-mails duplicados, e todas as linhas com um telefone no formato `+NN NNN NNN NNN`"
- **Mau:** "a lista está limpa"

Pergunta a ti mesmo: *um estranho, vendo só o meu critério e o resultado,
conseguiria dizer sim ou não sem precisar de me perguntar mais nada?* Se a
resposta for não, o revisor também não consegue. Prefere sempre critérios
que apontem para uma propriedade verificável (uma contagem, um formato, um
ficheiro que tem de existir, um teste que tem de passar) em vez de
critérios que descrevem apenas uma sensação de qualidade.

## Objetivos e ferramentas

Um objetivo não é um modo à parte: envolve um turno normal como outro
qualquer. O agente continua com todas as suas ferramentas disponíveis, e
pode ler ficheiros, consultar uma base de dados ou chamar uma API enquanto
persegue o objetivo. Só a **resposta final** de cada tentativa é que segue
para o revisor.

## Estado de trabalho dentro da conversa

O `pepe goal` conduz toda uma execução vista de fora. Já dentro da
conversa, duas ferramentas separadas dão ao agente um estado de trabalho
próprio, para que se mantenha coerente ao longo de muitos turnos em vez de
reagir mensagem a mensagem. Ambas pertencem à sessão, e por isso desaparecem
com ela, e tanto a chamada como o resultado aparecem na própria conversa e
em [Traces](/pt-pt/docs/traces/). São ferramentas normais como quaisquer
outras, presentes por omissão; se não quiseres que um agente acompanhe um
objetivo ou um plano ao longo dos turnos, tira `goal` e `update_plan` da
sua lista de ferramentas.

### `goal`: a estrela-guia

Aqui, um objetivo é uma meta persistente mais um estado. O agente define
um no arranque de uma tarefa não trivial, relê-o para se manter orientado, e
marca-o como concluído, ou bloqueado, no final. A ferramenta aceita quatro
ações:

- `set`: um `objective` (o que está a tentar alcançar), mais um
  `budget_tokens` opcional e meramente indicativo, para manter o esforço
  proporcional à tarefa.
- `status`: marca o objetivo como `active`, `paused`, `blocked` ou
  `complete`, com uma `note` opcional. O `blocked` é a forma de o agente
  dizer que está encravado e precisa de ti; o `complete` diz que a meta foi
  atingida.
- `show`: devolve o objetivo atual.
- `clear`: descarta-o.

A meta e o estado sobrevivem entre turnos e a um reinício, para que uma
execução longa ou autónoma não se desvie daquilo que se propôs a fazer.

<div class="note"><strong>O <code>budget_tokens</code> é um alvo indicativo, não um teto rígido.</strong> O agente sabe dele para manter o esforço proporcional, mas nada o obriga a cumpri-lo à letra. Os limites rígidos de despesa são o teto mensal por projeto, descrito em <a href="/pt-pt/docs/billing/">Utilização e faturação</a>.</div>

### `update_plan`: a lista de tarefas ao vivo

O `update_plan` mantém uma lista ordenada de passos, cada um marcado
`pending`, `in_progress` ou `done`. Cada chamada envia a lista **inteira** e
substitui a anterior por completo, de modo que existe sempre exatamente um
plano coerente. A lista já formatada volta em cada atualização:

```
Plan (1/3 done):
[x] read the failing test
[~] find the root cause
[ ] write the fix
```

O agente mantém sempre um único passo `in_progress` de cada vez, e vai
revendo a lista à medida que o trabalho avança. Uma lista `steps` vazia
limpa o plano por completo. Usa-o em trabalho de vários passos, onde vale a
pena o progresso ficar visível, e dispensa-o num pedido trivial de um só
passo.

### Como as ativar

```bash
pepe agent add worker --prompt "..." --tools bash,read_file,edit_file,goal,update_plan
```

Também dá para as acrescentares à lista de ferramentas de um agente já
existente a partir do painel, no separador Agents. Assim que ativadas, as
duas passam a aparecer em `pepe tools`.

### Ver o objetivo e o plano atuais

No painel, o separador Chat mostra um **painel de foco** estreito, logo
abaixo do cabeçalho da conversa selecionada: de um lado o objetivo, com a
meta e um selo de estado, do outro a lista do plano, ambos atualizados
enquanto o agente trabalha. E ficam visíveis também no próprio fluxo da
conversa, porque cada chamada a `goal` ou a `update_plan`, e o respetivo
resultado, aparecem tanto na conversa como em
[Traces](/pt-pt/docs/traces/).

## O que o ciclo de objetivo não é

- **Não** é um agendador. Para correr algo de forma recorrente, vê
  [Tarefas agendadas](/pt-pt/docs/scheduled/).
- **Não** é um vigia. Para seres avisado quando uma condição se torna
  verdadeira, vê [Watches](/pt-pt/docs/watches/).

Um objetivo tem fim: ou lá chega, ou desiste, e a partir daí está encerrado.
