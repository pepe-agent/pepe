---
title: Langfuse
description: Envie as execuções dos agentes pro Langfuse pra observabilidade, e gerencie a persona de um agente por um prompt do Langfuse em vez do config.json.
---

## Langfuse

O [Langfuse](https://langfuse.com) é uma conexão opcional, não um requisito -
nada no Pepe assume que ele está lá. Duas funcionalidades independentes usam
ele, e você pode ligar uma, as duas, ou nenhuma:

- **Export de traces**: toda execução concluída é enviada ao Langfuse como um
  trace OTLP, pra você navegar, depurar e avaliar execuções lá.
- **Prompts gerenciados**: a persona de um agente é buscada de um prompt que
  você edita no Langfuse, em vez de `system_prompt`/`SOUL.md`.

### Credenciais

As duas funcionalidades leem as mesmas variáveis de ambiente que todo SDK
oficial do Langfuse usa, então credenciais já configuradas pra outra
ferramenta funcionam aqui também:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
# Só se você não estiver no cloud.langfuse.com:
export LANGFUSE_BASE_URL=https://seu-langfuse-self-hosted.exemplo.com
```

Pegue o par de chaves nas configurações do seu projeto no Langfuse. Nenhuma
das duas funcionalidades faz nada até suas próprias credenciais estarem
definidas (veja abaixo - o export de traces lê um par de variáveis
diferente, o padrão do OTEL); uma indisponibilidade do Langfuse ou uma chave
errada só faz aquela funcionalidade específica cair pro comportamento local
silenciosamente, nunca trava uma conversa ou uma execução.

### Export de traces

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://cloud.langfuse.com/api/public/otel
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de pk-lf-...:sk-lf-...>"
```

Essas são as variáveis padrão do OTLP/OTEL, não o par `LANGFUSE_*` acima - o
endpoint OTLP do Langfuse autentica com um cabeçalho `Authorization` literal,
base64 de `chave-publica:chave-secreta`. Toda execução concluída vira um
trace OTLP: um span raiz pra execução inteira, um span filho por chamada de
ferramenta e por chamada de modelo, com atributos genéricos do OpenTelemetry
e os próprios do Langfuse definidos em cada um, então sessões são agrupadas
corretamente e gerações são distinguidas de spans de ferramenta comuns.
Desligado a menos que `OTEL_EXPORTER_OTLP_ENDPOINT` esteja definido; funciona
com qualquer outro backend que fale OTLP também, não só o Langfuse. Detalhe
completo, incluindo as duas variáveis extras do OTEL que você raramente
precisa: [Traces](../traces/#enviando-traces-para-uma-ferramenta-de-observabilidade).

### Prompts gerenciados

```bash
pepe agent add support --langfuse-prompt support-persona
```

Defina o `langfuse_prompt` de um agente (a flag do CLI acima, ou o mesmo
campo no editor de agente do dashboard) com o nome de um prompt no Langfuse,
e a persona desse agente passa a ser buscada de lá: edite o prompt no
Langfuse e a mudança chega ao Pepe em poucos minutos, sem redeploy. É
opt-in por agente; um agente sem `langfuse_prompt` definido fica totalmente
inalterado, e um cuja busca falhe (inacessível, nome não resolve) simplesmente
usa a persona local, exatamente como se isso nunca tivesse sido configurado.
Lê o par `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` acima. Detalhe completo:
[Agentes](../agents/#gerenciando-uma-persona-pelo-langfuse).
