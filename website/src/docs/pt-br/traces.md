---
title: Traces
description: Cada execução do agente deixa um registro que você pode reproduzir depois para ver exatamente o que ela fez.
---

Toda execução de um agente deixa um **trace**: um registro duradouro do que o
agente de fato fez, que você pode reproduzir passo a passo, não importa de onde
a execução partiu (a CLI, a API HTTP, um WebSocket, uma mensagem do Telegram ou
do WhatsApp, ou uma tarefa agendada). Um trace responde "por que o agente fez
aquilo?" muito depois de a execução ter terminado.

## O que um trace guarda

- O prompt que disparou a execução e como ela terminou (`ok`, ou um erro com o motivo).
- Quanto tempo levou e o consumo de tokens do modelo.
- O fluxo ordenado de passos: cada chamada de ferramenta **com os argumentos**, cada resultado de ferramenta, cada negação de permissão e cada troca de modelo por failover.
- A resposta final.

Execuções aninhadas de subagentes (um agente chamando outro por `send_to_agent`)
se dobram no mesmo trace, então um único registro mostra a árvore inteira de
trabalho.

## No painel

Abra **Traces** na barra lateral. A lista mostra as execuções mais recentes do
escopo do workspace atual, com o desfecho, a duração e as ferramentas que cada
uma usou. Clique em **Replay** em qualquer execução para percorrê-la passo a
passo: o prompt no topo e, em seguida, uma linha do tempo com cada chamada de
ferramenta, resultado, failover, contagem de tokens e a resposta final.

## Pela CLI

```bash
pepe traces                       # execuções recentes de todos os escopos
pepe traces --project acme        # apenas as execuções de um projeto
pepe traces --limit 10            # limita o tamanho da lista
pepe traces 1720000000123456      # reproduz uma execução por id, passo a passo
```

## Onde os traces ficam

Os traces ficam guardados no mesmo pequeno arquivo SQLite embutido dos compromissos e
das vigias, agrupados por projeto (o projeto default usa `default`). Cada projeto
guarda só uma quantidade limitada de traces: conforme novos chegam, os mais antigos
são apagados, então o arquivo nunca cresce sem limite. Argumentos e resultados de
ferramenta muito longos são encurtados antes de serem salvos.

<div class="note"><strong>Diagnóstico, não registro de cobrança.</strong> Os traces existem para explicar uma execução, e os antigos ou grandes demais vão sendo cortados. Para contagens de tokens que você pode faturar, use o <a href="../billing/">livro-razão de uso</a>, separado, que nunca perde um lançamento.</div>
