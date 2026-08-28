---
title: Objetivos
description: Faça um agente perseguir um resultado, verificado por um revisor independente, até que o trabalho esteja realmente pronto.
---

## Prompt versus perseguir um objetivo

Um prompt garante **um turno**. O agente responde e, a partir daí, é você quem decide se está bom, pede um ajuste, e o ciclo recomeça. Isso te coloca dentro do loop, como aprovador e como inspetor de qualidade ao mesmo tempo, e o trabalho só avança enquanto você está lá, na frente do teclado.

Um **objetivo** garante um **resultado**. Você define o que significa "pronto" e o Pepe segue trabalhando até que um revisor independente concorde que chegou lá, ou até esgotar as tentativas.

A diferença está em quem faz a verificação. Num turno comum, é o próprio agente que decide sozinho que terminou, e essa é exatamente a avaliação em que você não pode confiar. Num objetivo, quem julga o resultado contra o seu critério é uma **chamada separada ao modelo** (o mesmo padrão de critérios e passos de avaliação por trás do LLM-as-a-Judge).

## Rodando um objetivo

```bash
pepe goal "OBJETIVO" --criteria "como saber que terminou" \
  [--max-attempts 3] [--judge MODELO] [--agent NOME]
```

Um exemplo real:

```bash
pepe goal "limpar a lista de clientes em ~/dados/clientes.csv" \
  --criteria "sem e-mails duplicados, e toda linha com um telefone válido" \
  --max-attempts 4
```

O Pepe vai mostrando cada tentativa junto com o veredito do revisor:

```
── attempt 1/4 ──
[-> read_file clientes.csv]
[✓ read_file]
...
↻ reviewer: 3 rows still have an empty phone column

── attempt 2/4 ──
...
✅ reviewer: no duplicate emails remain and every row has a phone

✅ Goal met after 2 attempt(s).
```

No painel, dá para disparar de qualquer conversa:

```
/goal limpar a lista de clientes | sem e-mails duplicados, toda linha com telefone válido
```

A partir daí, o quadro acima da conversa passa a mostrar o critério, a contagem de tentativas e o último veredito do revisor, enquanto o trabalho segue.

## Como o revisor se mantém independente

O revisor entra numa chamada nova, com **contexto limpo**. Ele nunca vê a conversa de trabalho, só duas coisas: o seu critério e o resultado final. Por isso ele julga o artefato, não o raciocínio que levou até ele, e não tem como um agente confiante e errado convencê-lo a aprovar mesmo assim.

Por padrão, o revisor usa a mesma conexão de modelo do agente. Passar `--judge` dá a ele um modelo **diferente**, e essa é a configuração mais forte: um revisor independente é mais independente ainda quando não é o mesmo modelo corrigindo a própria prova.

```bash
pepe goal "..." --criteria "..." --judge gpt-5-review
```

Se a resposta do revisor voltar ilegível, o Pepe considera **não atingido**. Deixar passar um veredito que não dá para ler abriria a porta justamente para o que esse loop existe para barrar: um resultado ruim escapando sem ser notado.

## O teto de tentativas

O teto é **obrigatório** (3 por padrão, no máximo 10). Um critério que o agente jamais vai conseguir satisfazer precisa custar um número limitado de tentativas, nunca rodar para sempre. Ao bater o teto, o Pepe para, marca o objetivo como `blocked` e diz o que ainda faltava:

```
🛑 Gave up at the attempt cap. Still missing: 3 rows still have an empty phone column
```

Só essa mensagem já ajuda bastante: normalmente aponta para um critério impossível de cumprir, ou para um obstáculo real que merece a sua atenção.

## Escrevendo um critério que funcione

O critério é a funcionalidade inteira. Um critério vago transforma o revisor num cara ou coroa, e o loop nunca converge.

- **Bom:** "sem e-mails duplicados, e toda linha com um telefone no formato `+NN NNNNN-NNNN`"
- **Ruim:** "a lista está limpa"

Pergunte a si mesmo: um estranho, vendo só o critério e o resultado, conseguiria decidir sim ou não sem precisar te perguntar mais nada? Se a resposta for não, o revisor também não vai conseguir. Prefira sempre critérios que apontem uma propriedade verificável, como uma contagem, um formato, um arquivo que precisa existir, um teste que precisa passar, em vez de critérios que só descrevem uma sensação de qualidade.

## Objetivos e ferramentas

Um objetivo não é um modo especial: por baixo, ele é só um turno normal envolto em outra camada. O agente mantém todas as suas ferramentas, então continua podendo ler arquivos, consultar um banco ou chamar uma API enquanto persegue o objetivo. O que vai para o revisor é só a **resposta final** de cada tentativa.

## Estado de trabalho dentro de uma conversa

O `pepe goal` conduz uma execução inteira vista de fora. Já duas ferramentas separadas dão ao agente um estado de trabalho por **dentro**, para que ele se mantenha coerente ao longo de muitos turnos, em vez de reagir mensagem por mensagem. As duas pertencem à conversa: existem enquanto a sessão existir e somem com ela, e cada chamada, junto do resultado, aparece tanto no chat quanto nos [Traces](/pt-br/docs/traces/). Como qualquer outra ferramenta, ambas vêm habilitadas por padrão; remova `goal` e `update_plan` da lista de ferramentas de um agente se não quiser que ele acompanhe objetivo ou plano entre turnos.

### `goal`: a estrela-guia

Aqui, um objetivo é uma meta persistente somada a um status. O agente define um logo no início de uma tarefa não trivial, relê para não perder a orientação, e marca como concluído, ou bloqueado, ao final. A ferramenta aceita quatro ações:

- `set`: recebe um `objective` (o que se está tentando alcançar) e, opcionalmente, um alvo consultivo de `budget_tokens` para manter o esforço em proporção.
- `status`: marca o objetivo como `active`, `paused`, `blocked` ou `complete`, com uma `note` opcional. O `blocked` é como o agente avisa que travou e precisa de você; o `complete` diz que a meta foi cumprida.
- `show`: devolve o objetivo atual.
- `clear`: descarta o objetivo.

A meta e o status atravessam turnos e sobrevivem a um reinício, então uma execução longa, ou autônoma, não se perde do que se propôs a fazer.

<div class="note"><strong>O <code>budget_tokens</code> é um alvo consultivo, não um teto rígido.</strong> O agente sabe desse número para manter o esforço proporcional, mas nada o obriga a respeitá-lo. Limite rígido de gasto é o teto mensal por projeto, descrito em <a href="/pt-br/docs/billing/">Uso e cobrança</a>.</div>

### `update_plan`: a lista de tarefas viva

O `update_plan` mantém uma lista ordenada de passos, cada um marcado como `pending`, `in_progress` ou `done`. Cada chamada envia a lista **inteira** e substitui a anterior por completo, então existe sempre exatamente um plano coerente. A cada atualização, volta a lista já renderizada:

```
Plan (1/3 done):
[x] read the failing test
[~] find the root cause
[ ] write the fix
```

O agente mantém sempre um único passo `in_progress` por vez, e ajusta a lista conforme o trabalho avança. Enviar `steps` vazio limpa o plano inteiro. Vale usar em trabalho de várias etapas, onde o progresso precisa ficar visível, e dispensar num pedido trivial, de um passo só.

### Como habilitar

```bash
pepe agent add worker --prompt "..." --tools bash,read_file,edit_file,goal,update_plan
```

Dá para acrescentar as duas à lista de ferramentas de um agente já existente pelo painel também, na aba Agents. Depois de habilitadas, ambas aparecem em `pepe tools`.

### Vendo o objetivo e o plano atuais

No painel, a aba Chat mostra um **quadro de foco** enxuto logo abaixo do cabeçalho da conversa selecionada: de um lado o objetivo, com a meta e um selo de status; do outro, o checklist do plano, os dois se atualizando conforme o agente trabalha. Eles também aparecem no próprio fluxo da conversa, já que toda chamada de `goal` e `update_plan`, junto do resultado, fica registrada ali e nos [Traces](/pt-br/docs/traces/).

## O que o loop de objetivo não é

- **Não** é um agendador. Para rodar algo de forma recorrente, veja [Tarefas agendadas](/pt-br/docs/scheduled/).
- **Não** é um vigia. Para ser avisado quando uma condição se tornar verdadeira, veja [Watches](/pt-br/docs/watches/).

Um objetivo tem fim. Ou ele chega lá, ou desiste, e nos dois casos, acabou.
