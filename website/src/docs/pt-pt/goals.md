---
title: Objetivos
description: Executa um agente rumo a um resultado, verificado por um revisor independente, até estar mesmo concluído.
---

## Dar um prompt vs. perseguir um objetivo

Um prompt dá-te **um turno**. O agente responde, e depois és *tu* que decides se está bom, pedes um acerto, e repetes. Isso coloca-te dentro do ciclo como aprovador e inspetor de qualidade ao mesmo tempo, e o trabalho só avança enquanto estás à frente do teclado.

Um **objetivo** dá-te um **resultado**. Dizes o que significa "concluído", e o Pepe continua a trabalhar até um revisor independente concordar que lá chegou, ou até esgotar as tentativas.

A diferença está em **quem verifica**. Num turno normal é o próprio agente que decide que terminou, que é exatamente a avaliação em que não podes confiar. Num objetivo, uma **chamada separada ao modelo** avalia o resultado face ao teu critério.

## Executar um

```bash
pepe goal "OBJETIVO" --criteria "como sabemos que está concluído" \
  [--max-attempts 3] [--judge MODELO] [--agent NOME]
```

Um exemplo real:

```bash
pepe goal "limpar a lista de clientes em ~/dados/clientes.csv" \
  --criteria "sem e-mails duplicados, e todas as linhas com um telefone válido" \
  --max-attempts 4
```

O Pepe vai imprimindo cada tentativa e o veredito do revisor:

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

No painel, dispara-o a partir de qualquer conversa:

```
/goal limpar a lista de clientes | sem e-mails duplicados, todas as linhas com telefone válido
```

O painel acima da conversa passa a mostrar o critério, a contagem de tentativas e o último veredito do revisor enquanto trabalha.

## Como o revisor se mantém independente

O revisor é uma chamada nova, com **contexto limpo**. Nunca vê a conversa de trabalho, apenas duas coisas: o teu critério e o resultado final. Assim avalia o artefacto, não o raciocínio que o produziu, e não pode ser convencido a aprovar por um agente que está confiante e errado.

Por omissão o revisor usa a ligação de modelo do próprio agente. Passa `--judge` para lhe dar um modelo **diferente**, que é a configuração mais forte: um revisor independente é mais independente quando não é o mesmo modelo a corrigir o seu próprio teste.

```bash
pepe goal "..." --criteria "..." --judge gpt-5-review
```

Se a resposta do revisor vier ilegível, o Pepe conta como **não atingido**. Deixar passar com um veredito ilegível libertaria um mau resultado, que é precisamente o que este ciclo existe para evitar.

## O limite de tentativas

O limite é **obrigatório** (3 por omissão, no máximo 10). Um critério que o agente nunca conseguirá satisfazer tem de custar um número limitado de tentativas, não correr para sempre. Ao atingir o limite, o Pepe para, marca o objetivo como `blocked` e diz o que ainda faltava:

```
🛑 Gave up at the attempt cap. Still missing: 3 linhas continuam com a coluna de telefone vazia
```

Essa mensagem já vale por si: normalmente é ou um critério impossível, ou um obstáculo real que merece o teu olhar.

## Escrever um critério que funciona

O critério é a funcionalidade inteira. Um critério vago transforma o revisor num cara ou coroa, e o ciclo nunca converge.

- **Bom:** "sem e-mails duplicados, e todas as linhas com um telefone no formato `+NN NNN NNN NNN`"
- **Mau:** "a lista está limpa"

Pergunta a ti próprio: *um estranho, vendo apenas o meu critério e o resultado, conseguiria decidir sim ou não sem me perguntar nada?* Se não, o revisor também não consegue. Prefere critérios que nomeiem uma propriedade verificável (uma contagem, um formato, um ficheiro que tem de existir, um teste que tem de passar) a critérios que descrevem uma sensação de qualidade.

## Objetivos e ferramentas

Um objetivo não é um modo especial: envolve um turno normal. O agente continua com todas as suas ferramentas, por isso pode ler ficheiros, consultar uma base de dados ou chamar uma API enquanto trabalha rumo ao objetivo. Só a **resposta final** de cada tentativa vai para o revisor.

## Estado de trabalho dentro da conversa

O `pepe goal` conduz uma execução inteira a partir de fora. Duas ferramentas separadas dão ao agente um estado de trabalho **por dentro**, para que se mantenha coerente ao longo de muitos turnos, em vez de reagir a uma mensagem de cada vez. Ambas são por conversa: vivem com a sessão, no armazenamento descartável, e cada chamada e o seu resultado aparecem na conversa e nos [Traces](/pt-pt/docs/traces/). Ambas são opcionais, por isso acrescentas `goal` e `update_plan` à lista de ferramentas de um agente.

### `goal`: a estrela-guia

Um objetivo aqui é uma meta persistente mais um estado. O agente define um no início de uma tarefa não trivial, relê-o para se manter orientado, e marca-o como concluído (ou bloqueado) no fim. A ferramenta aceita quatro ações:

- `set`: um `objective` (o que está a tentar alcançar), mais um alvo opcional e meramente indicativo de `budget_tokens` para manter o esforço proporcional.
- `status`: marca o objetivo como `active`, `paused`, `blocked` ou `complete`, com uma `note` opcional. O `blocked` é a forma de o agente dizer que está encravado e precisa de ti; o `complete` significa que a meta foi atingida.
- `show`: devolve o objetivo atual.
- `clear`: descarta o objetivo.

A meta e o estado sobrevivem entre turnos e a um reinício, por isso uma execução longa ou autónoma não se desvia daquilo a que se propôs.

<div class="note"><strong>O <code>budget_tokens</code> é um alvo indicativo, não um teto rígido.</strong> O agente é informado dele para manter o esforço proporcional, e nada o obriga a respeitá-lo. Os limites rígidos de despesa são o teto mensal por projeto descrito em <a href="/pt-pt/docs/billing/">Utilização e faturação</a>.</div>

### `update_plan`: a lista de tarefas viva

O `update_plan` mantém uma lista ordenada de passos, cada um `pending`, `in_progress` ou `done`. Cada chamada passa a lista **inteira** e substitui a anterior, por isso existe sempre exatamente um plano coerente. A lista renderizada volta a cada atualização:

```
Plan (1/3 done):
[x] read the failing test
[~] find the root cause
[ ] write the fix
```

O agente mantém um passo `in_progress` de cada vez e revê a lista à medida que o trabalho evolui. Uma lista `steps` vazia limpa o plano. Usa-o em trabalho de vários passos, em que o progresso tem de ficar visível, e dispensa-o num pedido trivial de um só passo.

### Como as ativar

```bash
pepe agent add worker --prompt "..." --tools bash,read_file,edit_file,goal,update_plan
```

Também as podes acrescentar à lista de ferramentas de um agente existente através do painel, no separador Agents. Uma vez ativadas, ambas aparecem em `pepe tools`.

### Ver o objetivo e o plano atuais

No painel, o separador Chat mostra um **painel de foco** estreito por baixo do cabeçalho da conversa selecionada: o objetivo, com a meta e um selo de estado, e a lista do plano, ambos atualizados enquanto o agente trabalha. Também ficam visíveis no próprio fluxo, porque cada chamada de `goal` e `update_plan` e o respetivo resultado aparecem na conversa e nos [Traces](/pt-pt/docs/traces/).

## O que o ciclo de objetivo não é

- **Não** é um agendador. Para correr algo de forma recorrente, vê [Tarefas agendadas](/pt-pt/docs/scheduled/).
- **Não** é um vigia. Para seres avisado quando uma condição se tornar verdadeira, vê [Watches](/pt-pt/docs/watches/).

Um objetivo termina. Ou lá chega, ou desiste, e acabou.
