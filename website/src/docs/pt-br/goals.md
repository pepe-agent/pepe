---
title: Objetivos
description: Rode um agente rumo a um resultado, verificado por um revisor independente, até estar realmente pronto.
---

## Dar um prompt vs. perseguir um objetivo

Um prompt te compra **um turno**. O agente responde, e aí *você* decide se ficou bom, pede um ajuste, e repete. Isso te coloca dentro do loop como aprovador e inspetor de qualidade ao mesmo tempo, e o trabalho só anda enquanto você está na frente do teclado.

Um **objetivo** te compra um **resultado**. Você diz o que significa "pronto", e o Pepe continua trabalhando até um revisor independente concordar que chegou lá, ou até acabarem as tentativas.

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

No dashboard, dispare de qualquer chat:

```
/goal limpar a lista de clientes | sem e-mails duplicados, toda linha com telefone válido
```

O painel acima da conversa passa a mostrar o critério, a contagem de tentativas e o último veredito do revisor enquanto ele trabalha.

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

## O que o loop de objetivo não é

- **Não** é um agendador. Para rodar algo de forma recorrente, veja [Tarefas agendadas](/pt-br/docs/scheduled/).
- **Não** é um vigia. Para ser avisado quando uma condição se tornar verdadeira, veja [Watches](/pt-br/docs/watches/).

Um objetivo termina. Ou ele chega lá, ou desiste, e acabou.
