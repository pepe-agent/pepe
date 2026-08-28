---
title: Traces
description: Toda execução de um agente deixa um registro que dá para reproduzir depois, mostrando exatamente o que aconteceu.
---

Toda execução de agente deixa um **trace** para trás: um registro duradouro
do que aconteceu de verdade, reproduzível passo a passo, não importa se a
execução partiu da CLI, da API HTTP, de um WebSocket, de uma mensagem no
Telegram ou no WhatsApp, ou de uma tarefa agendada. É o trace que responde
"por que o agente fez aquilo?" muito depois de tudo já ter terminado.

## O que um trace guarda

- O prompt que disparou a execução e como ela terminou (`ok`, ou um erro com o motivo).
- Quanto tempo levou e quantos tokens de modelo foram consumidos.
- A sequência ordenada de passos: cada chamada de ferramenta **com seus argumentos**, o resultado de cada uma, toda negação de permissão e toda troca de modelo por failover.
- A resposta final.

Quando um agente chama outro por `send_to_agent`, essa subexecução entra no
mesmo trace do pai, então um único registro já mostra a árvore inteira de
trabalho.

## No painel

Abra **Traces** na barra lateral e você verá as execuções mais recentes do
workspace atual, com desfecho, duração e as ferramentas usadas em cada uma.
Clicar em **Replay** numa execução abre uma linha do tempo passo a passo: o
prompt no topo, depois cada chamada de ferramenta, resultado, failover,
contagem de tokens, até chegar na resposta final.

## Pela CLI

```bash
pepe traces                       # execuções recentes de todos os escopos
pepe traces --project acme        # apenas as execuções de um projeto
pepe traces --limit 10            # limita o tamanho da lista
pepe traces 1720000000123456      # reproduz uma execução por id, passo a passo
```

## Onde os traces ficam guardados

Traces vivem no mesmo pequeno arquivo SQLite embutido que guarda
compromissos e vigias, agrupados por projeto (o projeto default usa a chave
`default`). Cada projeto mantém só uma quantidade limitada deles: à medida
que traces novos chegam, os mais velhos vão sendo apagados, e o arquivo
nunca cresce indefinidamente. Argumentos e resultados de ferramenta longos
demais são encurtados antes de ir para o disco.

## Enviando traces para uma ferramenta de observabilidade

Mandar dados para o [Langfuse](../langfuse/) não pede nada além das
credenciais que a maioria das instalações já tem configurada
(`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`): assim que elas existem, toda
execução concluída sai como um trace OTLP; sem elas, nada é enviado. E uma
falha nesse envio jamais afeta a execução que estava sendo descrita.

Para qualquer outro backend que fale OTLP, use `OTEL_EXPORTER_OTLP_ENDPOINT`
no lugar, e ele assume o processo por completo:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://seu-coletor.exemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de usuario:senha>"
```

`OTEL_EXPORTER_OTLP_HEADERS` recebe uma lista `chave=valor` separada por
vírgulas, enviada como cabeçalhos literais na requisição. Cada span carrega
tanto os atributos genéricos do OpenTelemetry (`gen_ai.*`) quanto os
próprios do Langfuse (`langfuse.*`), então um endpoint Langfuse exibe tudo
por completo e qualquer outro backend OTLP também recebe o trace inteiro.
Há ainda duas variáveis padrão do OTEL que podem ser úteis:
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` redireciona o sinal de traces para um
caminho diferente de `<endpoint>/v1/traces`, e `OTEL_SERVICE_NAME` renomeia
o serviço exportado (o padrão é `pepe`). O passo a passo completo está em
[Langfuse](../langfuse/).

Além do prompt/resposta da execução e da entrada/saída de cada chamada de
ferramenta, todo trace exportado carrega também: o canal de origem
(Telegram, a API...) como metadado do trace; a chave da sessão como
`session.id`; um `user.id` que assume o nome de exibição de quem realmente
mandou a mensagem sempre que o canal consegue fornecer esse dado (Telegram,
mesmo numa conversa privada e não só na marcação de grupo; WhatsApp, a
partir do perfil do contato; Google Chat; Microsoft Teams; Discord),
caindo de volta para a chave da sessão quando o canal não tem esse nome
disponível, de forma que uma execução dentro de uma sessão compartilhada
(um grupo do Telegram, ou de um webhook) é atribuída a quem de fato a
enviou, e não a um id genérico cobrindo a conversa toda; a versão do Pepe
rodando naquele momento (`langfuse.release`); um nível
(`DEFAULT`/`WARNING`/`ERROR`) derivado de como a execução realmente
terminou; e, em cada span de chamada de modelo, o custo daquela chamada na
moeda configurada, calculado do mesmo jeito que o livro-razão de uso
calcula, e simplesmente omitido em vez de aparecer como um zero enganoso
quando o modelo não tem preço conhecido. Numa visualização em cascata, o
tempo de cada etapa (uma chamada de ferramenta, uma geração de modelo)
reflete o momento em que ela de fato aconteceu, não uma estimativa.

<div class="note"><strong>É diagnóstico, não registro de cobrança.</strong> Traces existem para explicar uma execução, e por isso os mais antigos ou grandes demais acabam sendo cortados. Para contagens de tokens e custos que você vai efetivamente faturar, use o <a href="../billing/">livro-razão de uso</a>, que é separado e nunca descarta um lançamento.</div>
