---
title: Langfuse
description: Envia as execuções dos agentes para o Langfuse para observabilidade, e gere a persona de um agente a partir de um prompt do Langfuse em vez do config.json.
---

## Langfuse

O [Langfuse](https://langfuse.com) é uma ligação opcional, não um requisito:
nada no Pepe assume que ele está lá. Duas funcionalidades usam-no:

- **Exportação de traces**: cada execução concluída é enviada ao Langfuse
  como um trace OTLP, para navegares, depurares e avaliares execuções lá.
- **Prompts geridos**: a persona de um agente é obtida a partir de um prompt
  que editas no Langfuse, em vez de `system_prompt`/`SOUL.md`. Opt-in por
  agente, além das credenciais abaixo, através de `langfuse_prompt`.

### Credenciais

Ambas as funcionalidades leem as mesmas variáveis de ambiente que qualquer
SDK oficial do Langfuse usa, pelo que credenciais já configuradas para outra
ferramenta funcionam aqui também:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
# Só se não estiveres no cloud.langfuse.com:
export LANGFUSE_BASE_URL=https://o-teu-langfuse-self-hosted.exemplo.com
```

Obtém o par de chaves nas definições do teu projeto no Langfuse. Defini-lo já
liga a exportação de traces de imediato, para todos os agentes (vê abaixo
se também queres prompts geridos pelo Langfuse, ou traces a irem para outro
sítio). Uma indisponibilidade do Langfuse ou uma chave errada faz a
exportação de traces cair silenciosamente para descartar o trace, e uma
obtenção de `langfuse_prompt` cair para a persona local do agente; nenhum
dos dois bloqueia uma conversa ou uma execução.

Ambas as funcionalidades leem estas variáveis diretamente do processo do
Pepe em execução, não pela ferramenta `bash` de um agente, o que importa
se algum dia pedires a um agente para ajudar a depurar a ligação.
`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` têm formato de segredo pelo
nome, pelo que o Pepe os remove da shell do próprio agente por predefinição,
tal como qualquer outra credencial (ver [Segredos](../secrets/)). O agente
ainda pode adicionar os dois nomes ao `secrets.expose_env` se precisar de os
verificar diretamente, só não esquecer que uma leitura de comprimento 0 ali
significa "removido da minha shell", não "não definido no servidor".

### Exportação de traces

O par `LANGFUSE_*` acima já chega sozinho: a exportação de traces liga assim
que `LANGFUSE_PUBLIC_KEY` e `LANGFUSE_SECRET_KEY` estão definidas, sem
precisares de nenhuma variável do OTEL em separado. Cada execução concluída
torna-se um trace OTLP: um span raiz para a execução inteira, um span filho
por chamada de ferramenta e por chamada de modelo, com atributos genéricos do
OpenTelemetry e os próprios do Langfuse definidos em cada um, pelo que as
sessões são agrupadas corretamente e as gerações são distinguidas de spans
de ferramenta comuns.

Para enviares traces para outro sítio que não o Langfuse (um coletor
self-hosted, o Honeycomb, qualquer outro backend que fale OTLP), define as
variáveis padrão do OTLP, e essas assumem por completo (o par `LANGFUSE_*`
passa a servir só para prompts geridos, se também usares isso):

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://o-teu-coletor.exemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de utilizador:senha>"
```

Detalhe completo, incluindo as duas variáveis extra do OTEL que raramente
precisas: [Traces](../traces/#enviar-traces-para-uma-ferramenta-de-observabilidade).

### Prompts geridos

```bash
pepe agent add support --langfuse-prompt support-persona
```

Define o `langfuse_prompt` de um agente (a flag do CLI acima, ou o mesmo
campo no editor de agente do dashboard) com o nome de um prompt no Langfuse,
e a persona desse agente passa a ser obtida de lá: edita o prompt no
Langfuse e a alteração chega ao Pepe dentro de poucos minutos, sem redeploy.
É opt-in por agente; um agente sem `langfuse_prompt` definido fica
completamente inalterado, e um cuja obtenção falhe (inacessível, o nome não
resolve) usa simplesmente a persona local, exatamente como se isto nunca
tivesse sido configurado. Lê o par `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`
acima. Detalhe completo: [Agentes](../agents/#gerir-uma-persona-a-partir-do-langfuse).
