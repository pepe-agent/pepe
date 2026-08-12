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

Enviar para o [Langfuse](../langfuse/) não precisa de nada além das
credenciais que a maioria das instalações já tem definidas para ele
(`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`): cada execução concluída torna-se
um trace OTLP assim que estão presentes, desligado caso contrário, e uma falha
no envio nunca afeta a execução que está a descrever.

Para qualquer outro backend que fale OTLP, define `OTEL_EXPORTER_OTLP_ENDPOINT`
em vez disso, e este assume por completo:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://o-teu-coletor.exemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de utilizador:senha>"
```

`OTEL_EXPORTER_OTLP_HEADERS` é uma lista `chave=valor` separada por vírgulas,
enviada como cabeçalhos literais do pedido. Tanto os atributos genéricos do
OpenTelemetry (`gen_ai.*`) como os próprios do Langfuse (`langfuse.*`) são
definidos em cada span, pelo que um endpoint Langfuse renderiza tudo por
completo e qualquer outro backend OTLP recebe na mesma um trace completo.
Mais duas variáveis padrão do OTEL, se precisares: `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`
aponta o sinal de traces para outro sítio além de `<endpoint>/v1/traces`, e
`OTEL_SERVICE_NAME` renomeia o serviço exportado (predefinição `pepe`). Passo
a passo completo: [Langfuse](../langfuse/).

Além da pergunta/resposta da execução e da entrada/saída de cada chamada de
ferramenta, cada trace exportado também traz: o canal de onde veio (Telegram,
a API...) como metadado do trace; a chave da sessão como `session.id`; o
`user.id`, ajustado para o nome de exibição de quem realmente enviou a
mensagem sempre que o canal consegue fornecer um (Telegram, incluindo numa
conversa privada, não só na marcação de grupo; WhatsApp, a partir do perfil
do contacto; Google Chat; Microsoft Teams; Discord), voltando para a chave
da sessão numa superfície sem esse nome disponível, de modo que uma
execução numa sessão partilhada (um grupo do Telegram ou de um webhook)
fica atribuída a quem realmente a enviou, em vez de um único id partilhado
para a conversa inteira; a versão do Pepe em execução (`langfuse.release`);
um nível (`DEFAULT`/`WARNING`/`ERROR`) derivado de como a execução realmente
terminou; e, em cada span de chamada de modelo, o custo dessa chamada na tua
moeda configurada, calculado da mesma forma que o livro-razão de utilização
calcula, e omitido por completo em vez de enviado como um zero enganador
quando o modelo não tem preço conhecido. O tempo de cada etapa numa
visualização em cascata (uma chamada de ferramenta, uma geração de modelo)
reflete quando ela realmente aconteceu, não uma estimativa.

<div class="note"><strong>Diagnóstico, não registo de faturação.</strong> Os traces existem para explicar uma execução, e os antigos ou demasiado grandes vão sendo cortados. Para contagens de tokens e custo que possas faturar, usa o <a href="../billing/">livro-razão de utilização</a>, separado, que nunca perde um lançamento.</div>
