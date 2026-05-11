---
title: Objetivos
description: Rode um agente rumo a um resultado, verificado por um revisor independente, até estar realmente pronto.
---

## Dar um prompt vs. perseguir um objetivo

Um prompt te dá **um turno**. O agente responde, e aí *você* decide se ficou bom, pede um ajuste, e repete. Isso te coloca dentro do loop como aprovador e inspetor de qualidade ao mesmo tempo, e o trabalho só anda enquanto você está na frente do teclado.

Um **objetivo** te dá um **resultado**. Você diz o que significa "pronto", e o Pepe continua trabalhando até um revisor independente concordar que chegou lá, ou até acabarem as tentativas.

A diferença está em **quem verifica**. Num turno normal é o próprio agente que decide que terminou, que é justamente a avaliação em que você não pode confiar. Num objetivo, uma **chamada separada ao modelo** julga o resultado contra o seu critério.

## Rodando um

```bash
pepe goal "OBJETIVO" --criteria "como sabemos que acabou" \
  [--max-attempts 3] [--judge MODELO] [--agent NOME]
```

Um exemplo real:

```bash
pepe goal "limpar a lista de clientes em ~/dados/clientes.csv" \
  --criteria "sem e-mails duplicados, e toda linha com um telefone válido" \
  --max-attempts 4
```

O Pepe vai imprimindo cada tentativa e o veredito do revisor:

```
── attempt 1/4 ──
[-> read_file clientes.csv]
[✓ read_file]
...
↻ reviewer: 3 linhas ainda estão com a coluna de telefone vazia

── attempt 2/4 ──
...
✅ reviewer: não há mais e-mails duplicados e toda linha tem telefone

✅ Goal met after 2 attempt(s).
```

No painel, dispare de qualquer chat:

```
/goal limpar a lista de clientes | sem e-mails duplicados, toda linha com telefone válido
```

O quadro acima da conversa passa a mostrar o critério, a contagem de tentativas e o último veredito do revisor enquanto ele trabalha.

## Como o revisor se mantém independente

O revisor é uma chamada nova, com **contexto limpo**. Ele nunca vê a conversa de trabalho, só duas coisas: o seu critério e o resultado final. Assim ele julga o artefato, não o raciocínio que o produziu, e não tem como ser convencido a aprovar por um agente que está confiante e errado.

Por padrão o revisor usa a conexão de modelo do próprio agente. Passe `--judge` para dar a ele um modelo **diferente**, que é a configuração mais forte: um revisor independente é mais independente quando não é o mesmo modelo corrigindo a própria prova.

```bash
pepe goal "..." --criteria "..." --judge gpt-5-review
```

Se a resposta do revisor vier ilegível, o Pepe conta como **não atingido**. Deixar passar com um veredito ilegível liberaria um resultado ruim, que é exatamente o que este loop existe para evitar.

## O teto de tentativas

O teto é **obrigatório** (3 por padrão, no máximo 10). Um critério que o agente nunca conseguirá satisfazer precisa custar um número limitado de tentativas, não rodar para sempre. Ao bater o teto, o Pepe para, marca o objetivo como `blocked` e diz o que ainda faltava:

```
🛑 Gave up at the attempt cap. Still missing: 3 linhas ainda estão com a coluna de telefone vazia
```

Essa mensagem já vale por si: normalmente é ou um critério impossível, ou um obstáculo real que merece o seu olhar.

## Escrevendo um critério que funciona

O critério é a feature inteira. Um critério vago transforma o revisor num cara ou coroa, e o loop nunca converge.

- **Bom:** "sem e-mails duplicados, e toda linha com um telefone no formato `+NN NNNNN-NNNN`"
- **Ruim:** "a lista está limpa"

Pergunte a si mesmo: *um estranho, vendo só o meu critério e o resultado, conseguiria decidir sim ou não sem me perguntar nada?* Se não, o revisor também não consegue. Prefira critérios que nomeiem uma propriedade verificável (uma contagem, um formato, um arquivo que precisa existir, um teste que precisa passar) a critérios que descrevem uma sensação de qualidade.

## Objetivos e ferramentas

Um objetivo não é um modo especial: ele envolve um turno normal. O agente continua com todas as suas ferramentas, então pode ler arquivos, consultar um banco ou chamar uma API enquanto trabalha rumo ao objetivo. Só a **resposta final** de cada tentativa vai para o revisor.

## Estado de trabalho dentro da conversa

O `pepe goal` conduz uma execução inteira de fora. Duas ferramentas separadas dão ao agente um estado de trabalho **por dentro**, para que ele se mantenha coerente ao longo de muitos turnos, em vez de reagir uma mensagem por vez. As duas são por conversa: vivem com a sessão, no armazenamento descartável, e cada chamada e seu resultado aparecem no chat e nos [Traces](/pt-br/docs/traces/). As duas são opcionais, então você adiciona `goal` e `update_plan` à lista de ferramentas de um agente.

### `goal`: a estrela-guia

Um objetivo aqui é uma meta persistente mais um status. O agente define um no início de uma tarefa não trivial, relê para se manter orientado, e o marca como concluído (ou bloqueado) no fim. A ferramenta aceita quatro ações:

- `set`: um `objective` (o que ele está tentando alcançar), mais um alvo opcional e consultivo de `budget_tokens` para manter o esforço proporcional.
- `status`: marca o objetivo como `active`, `paused`, `blocked` ou `complete`, com uma `note` opcional. O `blocked` é como o agente avisa que travou e precisa de você; o `complete` significa que a meta foi atingida.
- `show`: devolve o objetivo atual.
- `clear`: descarta o objetivo.

A meta e o status sobrevivem entre turnos e a um reinício, então uma execução longa ou autônoma não se desvia daquilo que se propôs a fazer.

<div class="note"><strong>O <code>budget_tokens</code> é um alvo consultivo, não um teto rígido.</strong> O agente é informado dele para manter o esforço proporcional, e nada o obriga a respeitá-lo. Os limites rígidos de gasto são o teto mensal por empresa descrito em <a href="/pt-br/docs/billing/">Uso e cobrança</a>.</div>

### `update_plan`: a lista de tarefas viva

O `update_plan` mantém uma lista ordenada de passos, cada um `pending`, `in_progress` ou `done`. Cada chamada passa a lista **inteira** e substitui a anterior, então existe sempre exatamente um plano coerente. A lista renderizada volta a cada atualização:

```
Plan (1/3 done):
[x] read the failing test
[~] find the root cause
[ ] write the fix
```

O agente mantém um passo `in_progress` por vez e revisa a lista conforme o trabalho evolui. Uma lista `steps` vazia limpa o plano. Use para trabalho de várias etapas, em que o progresso precisa ficar visível, e dispense em um pedido trivial de um passo só.

### Como habilitar

```bash
pepe agent add worker --prompt "..." --tools bash,read_file,edit_file,goal,update_plan
```

Você também pode adicioná-las à lista de ferramentas de um agente existente pelo painel, na aba Agents. Uma vez habilitadas, as duas aparecem em `pepe tools`.

### Vendo o objetivo e o plano atuais

No painel, a aba Chat mostra um **quadro de foco** estreito logo abaixo do cabeçalho da conversa selecionada: o objetivo, com a meta e um selo de status, e a lista do plano, os dois atualizados enquanto o agente trabalha. Eles também ficam visíveis no próprio fluxo, porque cada chamada de `goal` e `update_plan` e o resultado dela aparecem na conversa e nos [Traces](/pt-br/docs/traces/).

## O que o loop de objetivo não é

- **Não** é um agendador. Para rodar algo de forma recorrente, veja [Tarefas agendadas](/pt-br/docs/scheduled/).
- **Não** é um vigia. Para ser avisado quando uma condição se tornar verdadeira, veja [Watches](/pt-br/docs/watches/).

Um objetivo termina. Ou ele chega lá, ou desiste, e acabou.
