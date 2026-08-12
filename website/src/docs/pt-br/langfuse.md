---
title: Langfuse
description: Envie as execuções dos agentes para o Langfuse para observabilidade, e gerencie a persona de um agente por um prompt do Langfuse em vez do config.json.
---

## Langfuse

O [Langfuse](https://langfuse.com) é uma conexão opcional, não um requisito:
nada no Pepe assume que ele está lá. Duas funcionalidades usam ele:

- **Export de traces**: toda execução concluída é enviada ao Langfuse como um
  trace OTLP, para você navegar, depurar e avaliar execuções lá.
- **Prompts gerenciados**: a persona de um agente é buscada de um prompt que
  você edita no Langfuse, em vez de `system_prompt`/`SOUL.md`. Opt-in por
  agente, além das credenciais abaixo, via `langfuse_prompt`.

### Credenciais

As duas funcionalidades leem as mesmas variáveis de ambiente que todo SDK
oficial do Langfuse usa, então credenciais já configuradas para outra
ferramenta funcionam aqui também:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
# Só se você não estiver no cloud.langfuse.com:
export LANGFUSE_BASE_URL=https://seu-langfuse-self-hosted.exemplo.com
```

Obtenha o par de chaves nas configurações do seu projeto no Langfuse.
Defini-lo já liga o export de traces imediatamente, para todos os agentes
(veja abaixo se você também quer prompts gerenciados pelo Langfuse, ou
traces indo para outro destino). Uma indisponibilidade do Langfuse ou uma
chave errada faz o export de traces cair silenciosamente no comportamento
de descartar o trace, e uma busca de `langfuse_prompt` cair para a persona
local do agente; nenhum dos dois bloqueia uma conversa ou uma execução.

As duas funcionalidades leem essas variáveis diretamente do processo do
Pepe em execução, não pela ferramenta `bash` de um agente, o que importa se
algum dia você pedir a um agente para ajudar a depurar a conexão.
`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` têm formato de segredo pelo
nome, então o Pepe as remove do shell do próprio agente por padrão, assim
como qualquer outra credencial (veja [Segredos](../secrets/)). O agente
ainda pode adicionar os dois nomes ao `secrets.expose_env` se precisar
verificá-las diretamente; apenas tenha em mente que uma leitura de tamanho 0
ali significa "removida do meu shell", não "não definida no servidor".

### Export de traces

O par `LANGFUSE_*` acima já é suficiente por si só: o export de traces liga
assim que `LANGFUSE_PUBLIC_KEY` e `LANGFUSE_SECRET_KEY` estão definidas, sem
necessidade de nenhuma variável do OTEL separada. Toda execução concluída
vira um trace OTLP: um span raiz para a execução inteira, um span filho por
chamada de ferramenta e por chamada de modelo, com atributos genéricos do
OpenTelemetry e os próprios do Langfuse definidos em cada um, então sessões
são agrupadas corretamente e gerações são distinguidas de spans de
ferramenta comuns.

Para enviar traces a outro destino que não o Langfuse (um coletor
self-hosted, o Honeycomb, qualquer outro backend que fale OTLP), defina as
variáveis padrão do OTLP, e elas assumem completamente (o par `LANGFUSE_*`
passa a servir apenas para prompts gerenciados, se você também usar isso):

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://seu-coletor.exemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de usuario:senha>"
```

Detalhe completo, incluindo as duas variáveis extras do OTEL que você
raramente precisa:
[Traces](../traces/#enviando-traces-para-uma-ferramenta-de-observabilidade).

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
