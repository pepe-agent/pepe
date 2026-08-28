---
title: Traces
description: Cada execução de um agente fica registada e podes reproduzi-la mais tarde para ver exatamente o que aconteceu.
---

Cada execução de um agente deixa para trás um **trace**: um registo duradouro do que o agente fez de facto, reproduzível passo a passo, seja qual for a origem da execução (a CLI, a API HTTP, um WebSocket, uma mensagem do Telegram ou do WhatsApp, ou uma tarefa agendada). É o trace que responde, muito depois de a execução ter terminado, à pergunta "porque é que o agente fez aquilo?".

## O que fica guardado num trace

- O prompt que desencadeou a execução, e como ela terminou (`ok`, ou um erro com o respetivo motivo).
- Quanto tempo demorou e quantos tokens de modelo consumiu.
- O fluxo ordenado de passos: cada chamada de ferramenta **com os seus argumentos**, cada resultado, cada recusa de permissão e cada troca de modelo por failover.
- A resposta final.

Quando um agente chama outro através de `send_to_agent`, essas execuções aninhadas ficam dobradas dentro do mesmo trace, de forma a que um único registo mostre toda a árvore de trabalho.

## No painel

Abre **Traces** na barra lateral e vês as execuções mais recentes do âmbito de workspace atual, com o desfecho, a duração e as ferramentas usadas em cada uma. Ao clicar em **Replay** numa execução, percorres-la passo a passo: o prompt no topo, seguido de uma linha temporal com cada chamada de ferramenta, resultado, failover, contagem de tokens e a resposta final.

## Pela CLI

```bash
pepe traces                       # execuções recentes de todos os projetos
pepe traces --project acme        # só as execuções de um projeto
pepe traces --limit 10            # limita o tamanho da lista
pepe traces 1720000000123456      # reproduz uma execução por id, passo a passo
```

## Onde os traces ficam guardados

Os traces vivem no mesmo pequeno ficheiro SQLite embutido que guarda os compromissos e as vigilâncias, agrupados por projeto (o projeto default usa `default`). Cada projeto só mantém uma quantidade limitada de traces: à medida que chegam novos, os mais antigos vão sendo apagados, e o ficheiro nunca cresce sem limite. Argumentos e resultados de ferramenta demasiado longos são encurtados antes de serem guardados.

## Enviar traces para uma ferramenta de observabilidade

Para enviar para o [Langfuse](../langfuse/) basta ter as credenciais que a maioria das instalações já traz configuradas (`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`): assim que estão presentes, cada execução concluída é enviada como um trace OTLP; sem elas, o envio fica desligado, e uma falha na entrega nunca afeta a execução que estava a descrever.

Para qualquer outro backend que fale OTLP, define antes `OTEL_EXPORTER_OTLP_ENDPOINT`, que assume o controlo por completo:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://o-teu-coletor.exemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de utilizador:senha>"
```

`OTEL_EXPORTER_OTLP_HEADERS` é uma lista `chave=valor` separada por vírgulas, enviada tal e qual como cabeçalhos do pedido. Cada span carrega tanto os atributos genéricos do OpenTelemetry (`gen_ai.*`) como os próprios do Langfuse (`langfuse.*`), de modo que um endpoint Langfuse consegue renderizar tudo, e qualquer outro backend OTLP recebe, ainda assim, um trace completo. Há mais duas variáveis padrão do OTEL que podem ser úteis: `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, para apontar o sinal de traces para outro sítio que não `<endpoint>/v1/traces`, e `OTEL_SERVICE_NAME`, para renomear o serviço exportado (por predefinição, `pepe`). Passo a passo completo em [Langfuse](../langfuse/).

Além do par pergunta/resposta da execução e da entrada/saída de cada chamada de ferramenta, cada trace exportado carrega ainda: o canal de onde veio (Telegram, a API...) como metadado do trace; a chave de sessão como `session.id`; e um `user.id` ajustado ao nome de quem realmente enviou a mensagem sempre que o canal consegue fornecê-lo (Telegram, mesmo numa conversa privada e não só na marcação de grupo; WhatsApp, a partir do perfil do contacto; Google Chat; Microsoft Teams; Discord), recuando para a chave de sessão numa superfície sem esse nome disponível. Assim, uma execução dentro de uma sessão partilhada, como um grupo do Telegram ou de um webhook, fica atribuída a quem a enviou de facto, em vez de ficar tudo debaixo de um único id para a conversa inteira. Cada trace traz também a versão do Pepe em execução (`langfuse.release`), um nível (`DEFAULT`/`WARNING`/`ERROR`) derivado de como a execução realmente terminou, e, em cada span de chamada de modelo, o custo dessa chamada na moeda que configuraste, calculado da mesma forma que o livro-razão de utilização o calcula, e simplesmente omitido, em vez de aparecer como um zero enganador, quando o modelo não tem preço conhecido. O tempo de cada etapa numa visualização em cascata, seja uma chamada de ferramenta ou uma geração de modelo, reflete o momento em que aconteceu de facto, nunca uma estimativa.

<div class="note"><strong>Serve para diagnóstico, não para faturação.</strong> Os traces existem para explicar uma execução, e os mais antigos ou volumosos vão sendo eliminados. Para contagens de tokens e custos que possas faturar, usa antes o <a href="../billing/">livro-razão de utilização</a>, que é separado e nunca perde um lançamento.</div>
