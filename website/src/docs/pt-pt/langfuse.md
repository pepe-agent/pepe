---
title: Langfuse
description: Envia as execuções dos agentes para o Langfuse para observabilidade, e gere a persona de um agente a partir de um prompt do Langfuse em vez do config.json.
---

## Langfuse

O [Langfuse](https://langfuse.com) é uma ligação opcional, não um requisito -
nada no Pepe assume que ele está lá. Duas funcionalidades independentes
usam-no, e podes ligar uma, as duas, ou nenhuma:

- **Exportação de traces**: cada execução concluída é enviada ao Langfuse
  como um trace OTLP, para navegares, depurares e avaliares execuções lá.
- **Prompts geridos**: a persona de um agente é obtida a partir de um prompt
  que editas no Langfuse, em vez de `system_prompt`/`SOUL.md`.

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

Obtém o par de chaves nas definições do teu projeto no Langfuse. Nenhuma das
duas funcionalidades faz nada até as suas próprias credenciais estarem
definidas (ver abaixo - a exportação de traces lê um par de variáveis
diferente, o padrão do OTEL); uma indisponibilidade do Langfuse ou uma chave
errada só faz essa funcionalidade específica cair para o comportamento local
silenciosamente, nunca bloqueia uma conversa ou uma execução.

### Exportação de traces

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://cloud.langfuse.com/api/public/otel
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de pk-lf-...:sk-lf-...>"
```

Estas são as variáveis padrão do OTLP/OTEL, não o par `LANGFUSE_*` acima - o
endpoint OTLP do Langfuse autentica com um cabeçalho `Authorization` literal,
base64 de `chave-pública:chave-secreta`. Cada execução concluída torna-se um
trace OTLP: um span raiz para a execução inteira, um span filho por chamada
de ferramenta e por chamada de modelo, com atributos genéricos do
OpenTelemetry e os próprios do Langfuse definidos em cada um, pelo que as
sessões são agrupadas corretamente e as gerações são distinguidas de spans
de ferramenta comuns. Desligado a menos que `OTEL_EXPORTER_OTLP_ENDPOINT`
esteja definido; funciona também com qualquer outro backend que fale OTLP,
não só o Langfuse. Detalhe completo, incluindo as duas variáveis extra do
OTEL que raramente precisas: [Traces](../traces/#enviar-traces-para-uma-ferramenta-de-observabilidade).

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
