---
title: Flows
description: Promova uma sequência de chamadas de ferramenta comprovada e repetida em um script que roda de novo sem chamar o modelo.
---

## Por que isso existe

Um agente decide tudo do zero, todo turno, mesmo numa tarefa que já fez exatamente da mesma forma três vezes seguidas. Vale a pena pagar por isso nas primeiras vezes, enquanto o agente está descobrindo o que fazer. Deixa de valer a pena assim que a sequência já é confiável: a chamada ao modelo vira puro custo nesse ponto, e é mais um lugar onde uma execução pode sair diferente da anterior sem motivo.

Um **flow** é um [trace](../traces/) comprovado (ou vários) promovido a um script fixo: as chamadas de ferramenta exatas, na ordem certa, com os argumentos exatos, executadas de novo sem nenhuma chamada ao modelo. Ele só repete o que já aconteceu, argumento por argumento - não gera código novo, e não tenta adivinhar quais partes de uma chamada são "a mesma" e quais variam.

## Promovendo um flow

Olhe algumas execuções recentes que fizeram a mesma coisa da mesma forma:

```bash
pepe traces --project acme
```

Escolha duas ou mais que fizeram as chamadas de ferramenta idênticas, na mesma ordem, com os mesmos argumentos, e promova:

```bash
pepe flow promote weekly-digest --agent assistant --from 1784591017504516,1784591109332811
```

O Pepe confere se cada trace que você indicou realmente fez a mesma sequência exata antes de salvar qualquer coisa. Se não baterem - um argumento diferente, uma ordem diferente, um passo a mais em uma delas - a promoção é recusada, com uma mensagem explicando o motivo, em vez de tentar adivinhar o que você quis dizer:

```
✗ could not promote: those traces didn't make the exact same tool calls, in the same order,
  with the same arguments - flows only replay identical sequences
```

Essa recusa é proposital. Inferir automaticamente "essa parte varia, essa não" a partir de alguns exemplos é a única parte dessa ideia que é genuinamente arriscada - errar nisso e um flow passa a fazer, em silêncio, algo que nenhum dos traces de origem jamais fez. Um flow continua sendo replay exato e só isso; escolher traces que realmente são idênticos é responsabilidade sua, a mesma revisão que uma pessoa faria antes de confiar um script pra rodar sem supervisão.

## Gerenciando flows

```bash
pepe flow list --agent assistant                 # todos os flows desse agente
pepe flow show assistant weekly-digest            # os passos exatos que ele reproduz
pepe flow run assistant weekly-digest             # roda agora
pepe flow remove assistant weekly-digest
```

Promover de novo com o mesmo nome recusa a menos que você passe `--overwrite`, então uma promoção nova nunca substitui um flow existente em silêncio.

## Rodando numa agenda

Um flow vira uma tarefa recorrente do mesmo jeito que um prompt vira - pelo cron, só que sem prompt e sem chamada ao modelo:

```bash
pepe flow schedule assistant weekly-digest --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

Isso cria uma tarefa agendada (veja [Tarefas agendadas](../scheduled/)) do tipo `"flow"` em vez de `"prompt"`. Tudo sobre como ela dispara, o que acontece se a execução anterior ainda estiver rodando, e onde o histórico de execuções fica é o mesmo de qualquer outra tarefa agendada.

<div class="note"><strong>Ninguém está observando a execução de um flow.</strong> Um flow é disparado por um timer, não por uma conversa, então não há ninguém ali para aprovar um passo arriscado no momento. Um flow só executa um passo cuja ferramenta já está no <code>auto_approve</code> do próprio agente - a mesma regra que já governa qualquer outra superfície sem supervisão (um webhook, um token de API). Um passo que não está pré-aprovado interrompe o flow inteiro em vez de ser pulado em silêncio, e diz exatamente qual ferramenta precisava.</div>

Toda execução de flow ainda grava um [trace](../traces/) normal, então o histórico de um flow agendado é inspecionável do mesmo jeito que o de qualquer outra execução.
