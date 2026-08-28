---
title: Flows
description: Depois que um agente já resolveu o mesmo trabalho do mesmo jeito algumas vezes, transforme isso num script que reproduz exatamente aqueles passos, sem nenhuma chamada ao modelo.
---

## Por que isso existe

Todo turno, o agente refaz cada decisão do zero, mesmo numa tarefa idêntica a outras três que ele já resolveu do mesmíssimo jeito antes. Vale a pena pagar esse preço nas primeiras vezes, enquanto ele ainda está descobrindo o que fazer. Deixa de valer a partir do momento em que a sequência já se mostrou confiável: nesse ponto, a chamada ao modelo é puro custo extra, e ainda por cima é mais um lugar onde a execução pode sair diferente da anterior sem nenhum motivo real.

Um **flow** nasce de um ou mais [traces](../traces/) já comprovados, promovidos a um script fixo: as mesmas chamadas de ferramenta, na mesma ordem, com os mesmos argumentos, reproduzidas sem nenhuma chamada ao modelo. Ele repete exatamente o que já aconteceu, argumento por argumento. Não gera código novo, nem tenta adivinhar o que é "igual" e o que varia entre uma chamada e outra.

## Promovendo um flow

Comece olhando para execuções recentes que resolveram a mesma coisa do mesmo jeito:

```bash
pepe traces --project acme
```

Escolha duas ou mais que tenham feito chamadas de ferramenta idênticas, na mesma ordem e com os mesmos argumentos, e promova-as:

```bash
pepe flow promote weekly-digest --agent assistant --from 1784591017504516,1784591109332811
```

Antes de salvar qualquer coisa, o Pepe confere se todos os traces indicados realmente fizeram a sequência exata. Se algo não bater (um argumento diferente, uma ordem diferente, um passo a mais em algum deles), a promoção é recusada e vem com uma mensagem explicando o motivo, em vez de tentar adivinhar o que você quis dizer:

```
✗ could not promote: those traces didn't make the exact same tool calls, in the same order,
  with the same arguments - flows only replay identical sequences
```

Essa recusa é proposital. Inferir sozinho, a partir de alguns exemplos, o que "varia" e o que "não varia" seria a parte genuinamente arriscada dessa ideia: erre nisso, e o flow passa a fazer, em silêncio, algo que nenhum dos traces de origem jamais fez. Por isso um flow só reproduz o que é idêntico; cabe a você escolher traces realmente iguais, a mesma checagem que qualquer pessoa faria antes de confiar um script para rodar sozinho, sem supervisão.

A promoção também recusa um trace que não seja genuinamente "comprovado", ainda que a sequência bata: um que traga uma chamada barrada pela própria barreira de permissão do agente, um passo que de fato falhou, ou argumentos longos demais para terem sido registrados por completo (`Pepe.Trace` corta os que passam de um certo tamanho). Nenhum desses casos é uma chamada que você realmente viu dar certo. E recusa também traces que não foram todos gerados pelo agente para o qual você está promovendo, já que os caminhos relativos de um passo reproduzido são resolvidos dentro do workspace daquele agente específico.

## Gerenciando flows

```bash
pepe flow list --agent assistant                 # todos os flows desse agente
pepe flow show assistant weekly-digest            # os passos exatos que ele reproduz
pepe flow run assistant weekly-digest             # roda agora
pepe flow remove assistant weekly-digest
```

Promover de novo com o mesmo nome é recusado a menos que você passe `--overwrite`: assim, uma nova promoção nunca substitui, em silêncio, um flow que já existia.

## Rodando numa agenda

Um flow vira uma tarefa recorrente do mesmo jeito que um prompt: pelo cron, só que sem prompt algum e sem chamada ao modelo:

```bash
pepe flow schedule assistant weekly-digest --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

Isso cria uma tarefa agendada (veja [Tarefas agendadas](../scheduled/)) do tipo `"flow"`, em vez de `"prompt"`. No mais, tudo funciona como em qualquer outra tarefa agendada: como ela dispara, o que acontece se a execução anterior ainda estiver rodando, e onde fica o histórico.

<div class="note"><strong>Ninguém acompanha a execução de um flow em tempo real.</strong> Um flow dispara por um timer, não por uma conversa, então não há ninguém ali para aprovar um passo arriscado na hora. Por isso ele só executa um passo cuja ferramenta já esteja no <code>auto_approve</code> do próprio agente, a mesma regra que já vale para qualquer outra superfície sem supervisão direta, como um webhook ou um token de API. Um passo sem aprovação prévia, ou um passo que realmente falha ao ser reproduzido (um arquivo que sumiu, uma falha de rede, argumentos errados), interrompe o flow inteiro ali mesmo, em vez de pular esse passo ou seguir em frente de qualquer jeito. O histórico da execução mostra exatamente qual passo foi e por quê.</div>

Toda execução de flow também grava um [trace](../traces/) normal, então o histórico de um flow agendado pode ser inspecionado do mesmo jeito que o de qualquer outra execução.
