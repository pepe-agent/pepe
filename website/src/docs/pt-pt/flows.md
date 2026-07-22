---
title: Flows
description: Promove uma sequência de chamadas de ferramenta comprovada e repetida a um script que corre de novo sem chamar o modelo.
---

## Porque é que isto existe

Um agente decide tudo do zero, todo o turno, mesmo numa tarefa que já fez exatamente da mesma forma três vezes seguidas. Vale a pena pagar por isso nas primeiras vezes, enquanto o agente está a descobrir o que fazer. Deixa de valer a pena assim que a sequência já é fiável: a chamada ao modelo passa a ser puro custo nesse ponto, e é mais um sítio onde uma execução pode sair diferente da anterior sem motivo.

Um **flow** é um [trace](../traces/) comprovado (ou vários) promovido a um script fixo: as chamadas de ferramenta exatas, pela ordem certa, com os argumentos exatos, executadas de novo sem nenhuma chamada ao modelo. Só repete o que já aconteceu, argumento a argumento - não gera código novo, e não tenta adivinhar quais partes de uma chamada são "a mesma" e quais variam.

## Promover um flow

Vê algumas execuções recentes que fizeram a mesma coisa da mesma forma:

```bash
pepe traces --project acme
```

Escolhe duas ou mais que fizeram as chamadas de ferramenta idênticas, pela mesma ordem, com os mesmos argumentos, e promove:

```bash
pepe flow promote weekly-digest --agent assistant --from 1784591017504516,1784591109332811
```

O Pepe confirma se cada trace que indicaste fez mesmo a sequência exata antes de gravar seja o que for. Se não coincidirem - um argumento diferente, uma ordem diferente, um passo a mais numa delas - a promoção é recusada, com uma mensagem a explicar porquê, em vez de tentar adivinhar o que quiseste dizer:

```
✗ could not promote: those traces didn't make the exact same tool calls, in the same order,
  with the same arguments - flows only replay identical sequences
```

Essa recusa é propositada. Inferir automaticamente "esta parte varia, esta não" a partir de alguns exemplos é a única parte desta ideia que é genuinamente arriscada - errar nisso e um flow passa a fazer, em silêncio, algo que nenhum dos traces de origem alguma vez fez. Um flow continua a ser replay exato e só isso; escolher traces que realmente são idênticos é responsabilidade tua, a mesma revisão que uma pessoa faria antes de confiar um script para correr sem supervisão.

## Gerir flows

```bash
pepe flow list --agent assistant                 # todos os flows desse agente
pepe flow show assistant weekly-digest            # os passos exatos que reproduz
pepe flow run assistant weekly-digest             # corre agora
pepe flow remove assistant weekly-digest
```

Promover de novo com o mesmo nome recusa a não ser que passes `--overwrite`, por isso uma promoção nova nunca substitui um flow existente em silêncio.

## Correr numa agenda

Um flow passa a tarefa recorrente da mesma forma que um prompt - pelo cron, só que sem prompt e sem chamada ao modelo:

```bash
pepe flow schedule assistant weekly-digest --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

Isto cria uma tarefa agendada (ver [Tarefas agendadas](../scheduled/)) do tipo `"flow"` em vez de `"prompt"`. Tudo sobre como dispara, o que acontece se a execução anterior ainda estiver a correr, e onde fica o histórico de execuções é igual ao de qualquer outra tarefa agendada.

<div class="note"><strong>Ninguém está a observar a execução de um flow.</strong> Um flow é disparado por um temporizador, não por uma conversa, por isso não há ninguém ali para aprovar um passo arriscado no momento. Um flow só executa um passo cuja ferramenta já está no <code>auto_approve</code> do próprio agente - a mesma regra que já governa qualquer outra superfície sem supervisão (um webhook, um token de API). Um passo que não está pré-aprovado interrompe o flow inteiro em vez de ser saltado em silêncio, e diz exatamente que ferramenta precisava.</div>

Toda a execução de um flow continua a gravar um [trace](../traces/) normal, por isso o histórico de um flow agendado é inspecionável da mesma forma que o de qualquer outra execução.
