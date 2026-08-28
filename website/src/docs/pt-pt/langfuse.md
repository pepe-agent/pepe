---
title: Langfuse
description: Envia as execuções dos agentes para o Langfuse para efeitos de observabilidade, e gere a persona de um agente a partir de um prompt do Langfuse, em vez do config.json.
---

## Langfuse

O [Langfuse](https://langfuse.com) é uma ligação opcional, nunca um requisito: o Pepe não assume em lado nenhum que ela existe. Há duas funcionalidades que a usam:

- **Exportação de traces**: toda a execução terminada segue para o Langfuse como um trace OTLP, o que te dá navegação, depuração e avaliação de execuções diretamente lá.
- **Prompts geridos**: em vez de `system_prompt`/`SOUL.md`, a persona de um agente passa a vir de um prompt que editas no Langfuse. É opt-in, agente a agente, por cima das credenciais abaixo, através de `langfuse_prompt`.

### Credenciais

As duas funcionalidades partilham as mesmas variáveis de ambiente de qualquer SDK oficial do Langfuse, por isso credenciais que já tenhas configurado para outra ferramenta servem aqui sem mais trabalho:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
# Só é preciso se não estiveres no cloud.langfuse.com:
export LANGFUSE_BASE_URL=https://o-teu-langfuse-self-hosted.exemplo.com
```

O par de chaves está nas definições do teu projeto no Langfuse. Assim que o defines, a exportação de traces liga-se de imediato para todos os agentes (mais abaixo explica-se como ter também os prompts geridos pelo Langfuse, ou enviar os traces para outro destino qualquer). Uma falha do Langfuse ou uma chave errada não trava nada: a exportação de traces limita-se a descartar o trace em silêncio, e uma obtenção de `langfuse_prompt` recua para a persona local do agente. Nenhum dos dois casos chega a bloquear uma conversa ou uma execução.

Estas variáveis são lidas diretamente do processo do Pepe em execução, nunca através da ferramenta `bash` de um agente, algo que importa saber se alguma vez pedires a um agente para te ajudar a depurar a ligação. Como `LANGFUSE_PUBLIC_KEY` e `LANGFUSE_SECRET_KEY` têm nome de segredo, o Pepe remove-as por predefinição da shell do próprio agente, tal como faz com qualquer outra credencial (ver [Segredos](../secrets/)). Se precisar mesmo de as confirmar, o agente pode adicionar os dois nomes a `secrets.expose_env`; só tem de saber que uma leitura de comprimento zero nesse caso quer dizer "removida da minha shell", e não "por definir no servidor".

### Exportação de traces

Basta o par `LANGFUSE_*` acima: a exportação de traces liga-se no instante em que `LANGFUSE_PUBLIC_KEY` e `LANGFUSE_SECRET_KEY` estão ambas definidas, sem qualquer variável do OTEL à parte. Cada execução terminada vira um único trace OTLP, com um span raiz para a execução inteira e um span filho por cada chamada de ferramenta e por cada chamada de modelo. Cada span leva atributos genéricos de OpenTelemetry e os atributos próprios do Langfuse, o que faz as sessões agruparem-se corretamente e distingue as gerações dos spans de ferramenta comuns.

Se preferires mandar os traces para outro lado que não o Langfuse (um coletor self-hosted, o Honeycomb, qualquer backend que fale OTLP), define antes as variáveis padrão do OTLP: elas assumem por completo o controlo (o par `LANGFUSE_*` fica então só a servir os prompts geridos, caso também os uses):

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://o-teu-coletor.exemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de utilizador:senha>"
```

O detalhe completo, incluindo as duas variáveis extra do OTEL de que raramente vais precisar, está em [Traces](../traces/#enviar-traces-para-uma-ferramenta-de-observabilidade).

### Prompts geridos

```bash
pepe agent add support --langfuse-prompt support-persona
```

Define o `langfuse_prompt` de um agente com o nome de um prompt no Langfuse, seja pela flag do CLI acima ou pelo mesmo campo no editor de agentes do painel, e a persona desse agente passa a vir de lá. Editas o prompt no Langfuse e a mudança chega ao Pepe dentro de poucos minutos, sem qualquer redeploy. Continua a ser opt-in por agente: um agente sem `langfuse_prompt` fica totalmente por afetar, e um cujo pedido falhe (servidor inacessível, nome que não resolve) usa a persona local sem mais, como se isto nunca tivesse sido ligado. Lê o mesmo par `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` de cima. Detalhe completo em [Agentes](../agents/#gerir-uma-persona-a-partir-do-langfuse).
