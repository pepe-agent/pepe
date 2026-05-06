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

## O que o ciclo de objetivo não é

- **Não** é um agendador. Para correr algo de forma recorrente, vê [Tarefas agendadas](/pt-pt/docs/scheduled/).
- **Não** é um vigia. Para seres avisado quando uma condição se tornar verdadeira, vê [Watches](/pt-pt/docs/watches/).

Um objetivo termina. Ou lá chega, ou desiste, e acabou.
