---
title: Flows
description: Depois de um agente repetir o mesmo trabalho da mesma forma algumas vezes, transforma isso num script que reproduz exatamente esses passos, sem nenhuma chamada ao modelo.
---

## Porque é que isto existe

Em cada turno, o agente refaz cada decisão do zero, mesmo numa tarefa idêntica a outras três que já resolveu exatamente da mesma forma antes. Vale a pena pagar esse custo nas primeiras vezes, enquanto ele ainda está a descobrir o que fazer. Deixa de valer a pena quando a sequência já se revelou fiável: a partir daí, a chamada ao modelo é puro desperdício, e ainda por cima abre a porta a uma execução sair diferente da anterior sem nenhuma razão para isso.

Um **flow** promove um [trace](../traces/) comprovado (ou vários) a um script fixo: as mesmas chamadas de ferramenta, pela mesma ordem, com os mesmos argumentos, repetidas sem qualquer chamada ao modelo. Limita-se a repetir o que já aconteceu, argumento por argumento; não gera código novo nem tenta adivinhar que partes de uma chamada são fixas e quais variam.

## Promover um flow

Olha para algumas execuções recentes que fizeram a mesma coisa da mesma maneira:

```bash
pepe traces --project acme
```

Escolhe duas ou mais que tenham feito chamadas de ferramenta idênticas, na mesma ordem e com os mesmos argumentos, e promove-as:

```bash
pepe flow promote weekly-digest --agent assistant --from 1784591017504516,1784591109332811
```

Antes de gravar seja o que for, o Pepe confirma que todos os traces indicados fizeram mesmo a sequência exata. Se algo não bater certo (um argumento diferente, uma ordem trocada, um passo a mais numa delas), a promoção é recusada, com uma mensagem a explicar porquê, em vez de tentar adivinhar o que querias dizer:

```
✗ could not promote: those traces didn't make the exact same tool calls, in the same order,
  with the same arguments - flows only replay identical sequences
```

Esta recusa é propositada. Inferir sozinho, a partir de um punhado de exemplos, "isto varia, aquilo não varia" é a única parte desta ideia que é realmente arriscada: erra nisso e um flow passa a fazer, em silêncio, algo que nenhum dos traces de origem alguma vez fez. Um flow fica sempre limitado à repetição exata; escolher traces que são mesmo idênticos é trabalho teu, a mesma revisão que qualquer pessoa faria antes de confiar um script para correr sem ninguém a vigiar.

A promoção recusa também um trace que não seja genuinamente "comprovado", ainda que a sequência bata certo: um que inclua uma chamada que a barreira de permissão do próprio agente recusou, um passo que de facto falhou, ou argumentos longos demais para terem ficado registados por inteiro (o `Pepe.Trace` corta os muito extensos antes de os guardar). Nada disso é uma chamada que tenhas mesmo visto correr bem. Também recusa traces que não foram todos produzidos pelo agente para o qual estás a promover, porque os caminhos relativos de um passo reproduzido se resolvem dentro do workspace desse agente, e de mais nenhum.

## Gerir flows

```bash
pepe flow list --agent assistant                 # todos os flows desse agente
pepe flow show assistant weekly-digest            # os passos exatos que reproduz
pepe flow run assistant weekly-digest             # corre agora
pepe flow remove assistant weekly-digest
```

Promover de novo com o mesmo nome é recusado, a menos que passes `--overwrite`; assim, uma promoção nova nunca substitui silenciosamente um flow já existente.

## Correr numa agenda

Um flow torna-se uma tarefa recorrente da mesma forma que um prompt, através do cron, só que sem prompt e sem chamada ao modelo:

```bash
pepe flow schedule assistant weekly-digest --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

Isto cria uma tarefa agendada (ver [Tarefas agendadas](../scheduled/)) do tipo `"flow"`, em vez de `"prompt"`. Tudo o resto, como dispara, o que acontece se a execução anterior ainda estiver a decorrer, onde fica guardado o histórico, funciona exatamente como em qualquer outra tarefa agendada.

<div class="note"><strong>Ninguém está a vigiar a execução de um flow.</strong> Um flow dispara a partir de um temporizador, não de uma conversa, por isso não há ali ninguém para aprovar um passo arriscado no momento. Um flow só executa um passo cuja ferramenta já esteja no <code>auto_approve</code> do próprio agente, a mesma regra que já governa qualquer outra superfície sem ninguém a acompanhar (um webhook, um token de API). Um passo que não esteja pré-aprovado, ou que falhe mesmo ao ser reproduzido (um ficheiro em falta, um soluço de rede, argumentos errados), trava o flow inteiro ali mesmo, em vez de o saltar ou seguir em frente; o histórico da execução mostra exatamente qual foi o passo e porquê.</div>

Toda a execução de um flow continua a gravar um [trace](../traces/) normal, por isso o histórico de um flow agendado pode ser inspecionado da mesma forma que o de qualquer outra execução.
