---
title: Traces
description: Um registo durável e reproduzível daquilo que cada execução do agente fez de facto.
---

Cada execução de um agente deixa um **trace**: um registo durável e reproduzível
daquilo que o agente fez de facto, seja qual for a superfície que a desencadeou (a
CLI, a API HTTP, um WebSocket, uma mensagem do Telegram ou do WhatsApp, ou uma
tarefa agendada). Um trace responde à pergunta "porque é que o agente fez aquilo?"
muito depois de a execução ter terminado.

## O que um trace guarda

- O prompt que desencadeou a execução e como ela terminou (`ok`, ou um erro com o motivo).
- Quanto tempo demorou e o consumo de tokens do modelo.
- O fluxo ordenado de passos: cada chamada de ferramenta **com os seus argumentos**, cada resultado de ferramenta, cada recusa de permissão e cada troca de modelo por failover.
- A resposta final.

As execuções aninhadas de subagentes (um agente que chama outro através de
`send_to_agent`) dobram-se no mesmo trace, por isso um único registo mostra toda a
árvore de trabalho.

## No painel

Abre **Traces** na barra lateral. A lista mostra as execuções mais recentes do
âmbito da workspace atual, com o desfecho, a duração e as ferramentas que cada uma
usou. Carrega em **Replay** numa execução para a percorrer passo a passo: o prompt
no topo e, a seguir, uma linha temporal com cada chamada de ferramenta, resultado,
failover, contagem de tokens e a resposta final.

## Pela CLI

```bash
pepe traces                       # execuções recentes de todos os âmbitos
pepe traces --project acme        # apenas as execuções de um projeto
pepe traces --limit 10            # limita o tamanho da lista
pepe traces 1720000000123456      # reproduz uma execução por id, passo a passo
```

## Onde ficam os traces

Os traces são escritos como um ficheiro JSON por execução, em
`<PEPE_HOME>/data/traces/<slug>/<id>.json`, e o projeto default fica sob `default/`. O
diretório tem um teto por âmbito, por isso os traces mais antigos vão sendo
descartados e ele mantém-se limitado. Argumentos e resultados de ferramenta muito
longos são cortados no registo guardado.

<div class="note"><strong>Diagnóstico, não registo de faturação.</strong> Os traces existem para explicar uma execução, e são descartados e cortados para se manterem limitados. A contabilidade de tokens para faturas vive no <a href="../billing/">livro-razão de utilização</a>, separado e só de acréscimo.</div>
