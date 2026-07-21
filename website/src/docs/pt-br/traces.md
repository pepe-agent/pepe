---
title: Traces
description: Um registro durável e reproduzível do que cada execução do agente realmente fez.
---

Toda execução de um agente deixa um **trace**: um registro durável e reproduzível
do que o agente de fato fez, não importa qual superfície disparou a execução (a
CLI, a API HTTP, um WebSocket, uma mensagem do Telegram ou do WhatsApp, ou uma
tarefa agendada). Um trace responde "por que o agente fez aquilo?" muito depois
de a execução ter terminado.

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

Os traces vivem no mesmo pequeno arquivo SQLite embutido dos compromissos e das vigias,
agrupados por projeto (o projeto default usa `default`). A quantidade guardada tem um
teto por projeto, então os traces mais antigos vão sendo descartados e a tabela se
mantém limitada. Argumentos e resultados de ferramenta muito longos são cortados no
registro salvo. Atualizando de um Pepe mais antigo que gravava os traces como um arquivo
JSON por execução em `<PEPE_HOME>/data/traces/<slug>/<id>.json`? Rode `mix pepe config
migrate-data` uma vez pra trazer os antigos - os arquivos de origem ficam intactos, não
são apagados, então você pode remover essa pasta na mão depois de confirmar a importação.

<div class="note"><strong>Diagnóstico, não registro de cobrança.</strong> Os traces existem para explicar uma execução, e são descartados e cortados para se manterem limitados. A contabilidade de tokens para faturamento vive no <a href="../billing/">livro-razão de uso</a>, separado e somente-acréscimo.</div>
