---
title: Traces
description: Cada execução do agente deixa um registo que podes reproduzir mais tarde para veres exatamente o que ela fez.
---

Cada execução de um agente deixa um **trace**: um registo duradouro daquilo que o
agente fez de facto, que podes reproduzir passo a passo, venha a execução de onde
vier (a CLI, a API HTTP, um WebSocket, uma mensagem do Telegram ou do WhatsApp, ou
uma tarefa agendada). Um trace responde à pergunta "porque é que o agente fez
aquilo?" muito depois de a execução ter terminado.

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

Os traces ficam guardados no mesmo pequeno ficheiro SQLite embutido dos compromissos e
das vigilâncias, agrupados por projeto (o projeto default usa `default`). Cada projeto
guarda apenas uma quantidade limitada de traces: à medida que chegam novos, os mais
antigos são apagados, por isso o ficheiro nunca cresce sem limite. Argumentos e
resultados de ferramenta muito longos são encurtados antes de serem guardados.

## Enviar traces para uma ferramenta de observabilidade

Define `OTEL_EXPORTER_OTLP_ENDPOINT` e cada execução concluída também é enviada
como um trace OTLP, para o Langfuse ou qualquer outro backend que fale esse
protocolo — desligado até definires isto, e uma falha no envio nunca afeta a
execução que está a descrever.

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://cloud.langfuse.com/api/public/otel
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de pk-lf-...:sk-lf-...>"
```

`OTEL_EXPORTER_OTLP_HEADERS` é uma lista `chave=valor` separada por vírgulas,
enviada como cabeçalhos literais do pedido: o par de chaves de autenticação do
Langfuse vai aqui, sem qualquer configuração específica do Langfuse noutro
sítio. Tanto os atributos genéricos do OpenTelemetry (`gen_ai.*`) como os
próprios do Langfuse (`langfuse.*`) são definidos em cada span, pelo que um
endpoint Langfuse renderiza tudo por completo (sessões agrupadas, painéis de
entrada/saída, gerações distinguidas de spans de ferramenta comuns), e
qualquer outro backend OTLP recebe na mesma um trace completo.

Mais duas variáveis padrão do OTEL, se precisares: `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`
aponta o sinal de traces para outro sítio além de `<endpoint>/v1/traces`, e
`OTEL_SERVICE_NAME` renomeia o serviço exportado (predefinição `pepe`).

<div class="note"><strong>Diagnóstico, não registo de faturação.</strong> Os traces existem para explicar uma execução, e os antigos ou demasiado grandes vão sendo cortados. Para contagens de tokens que possas faturar, usa o <a href="../billing/">livro-razão de utilização</a>, separado, que nunca perde um lançamento.</div>
