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

## Enviando traces para uma ferramenta de observabilidade

Enviar para o [Langfuse](../langfuse/) não precisa de nada além das
credenciais que a maioria das instalações já tem definidas para ele
(`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`): toda execução concluída vira
um trace OTLP assim que elas estão presentes, desligado caso contrário, e uma
falha no envio nunca afeta a execução que ela está descrevendo.

Para qualquer outro backend que fale OTLP, defina `OTEL_EXPORTER_OTLP_ENDPOINT`
em vez disso, e ele assume completamente:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://seu-coletor.exemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de usuario:senha>"
```

`OTEL_EXPORTER_OTLP_HEADERS` é uma lista `chave=valor` separada por vírgulas,
enviada como cabeçalhos literais da requisição. Tanto os atributos genéricos
do OpenTelemetry (`gen_ai.*`) quanto os próprios do Langfuse (`langfuse.*`)
são definidos em cada span, então um endpoint Langfuse renderiza tudo
completo e qualquer outro backend OTLP recebe um trace completo do mesmo
jeito. Mais duas variáveis padrão do OTEL, se precisar:
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` aponta o sinal de traces pra outro lugar
além de `<endpoint>/v1/traces`, e `OTEL_SERVICE_NAME` renomeia o serviço
exportado (padrão `pepe`). Passo a passo completo: [Langfuse](../langfuse/).

Além da pergunta/resposta da execução e da entrada/saída de cada chamada de
ferramenta, cada trace exportado também traz: o canal de onde veio (Telegram,
a API...) como metadado do trace; a chave da sessão como `session.id`; o
`user.id`, ajustado para o nome de exibição de quem realmente enviou a
mensagem sempre que o canal consegue fornecer um (Telegram, inclusive numa
conversa privada, não só na marcação de grupo; WhatsApp, a partir do perfil
do contato; Google Chat; Microsoft Teams; Discord), voltando para a chave da
sessão numa superfície sem esse nome disponível, de modo que uma execução
numa sessão compartilhada (um grupo do Telegram ou de um webhook) fica
atribuída a quem realmente a enviou, em vez de um único id compartilhado
para a conversa inteira; a versão do Pepe em execução (`langfuse.release`);
um nível (`DEFAULT`/`WARNING`/`ERROR`) derivado de como a execução realmente
terminou; e, em cada span de chamada de modelo, o custo dessa chamada na sua
moeda configurada, calculado da mesma forma que o livro-razão de uso
calcula, e omitido por completo em vez de enviado como um zero enganoso
quando o modelo não tem preço conhecido. O tempo de cada etapa numa
visualização em cascata (uma chamada de ferramenta, uma geração de modelo)
reflete quando ela realmente aconteceu, não uma estimativa.

<div class="note"><strong>Diagnóstico, não registro de cobrança.</strong> Os traces existem para explicar uma execução, e os antigos ou grandes demais vão sendo cortados. Para contagens de tokens e custo que você pode faturar, use o <a href="../billing/">livro-razão de uso</a>, separado, que nunca perde um lançamento.</div>
