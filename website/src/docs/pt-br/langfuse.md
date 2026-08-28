---
title: Langfuse
description: Mande as execuções dos seus agentes para o Langfuse e acompanhe tudo em observabilidade, ou deixe a persona de um agente sob o comando de um prompt gerenciado lá, em vez do config.json.
---

## Langfuse

O [Langfuse](https://langfuse.com) não é uma dependência do Pepe, é uma conexão opcional: nada aqui pressupõe que ele exista. Duas funcionalidades usam essa conexão quando ela está configurada:

- **Export de traces**: cada execução concluída vira um trace OTLP no Langfuse, pronto para você navegar, depurar e avaliar por lá.
- **Prompts gerenciados**: em vez de manter a persona de um agente em `system_prompt` ou num `SOUL.md`, você edita esse texto como um prompt dentro do Langfuse. É opt-in, agente por agente, através do campo `langfuse_prompt`, além das credenciais abaixo.

### Credenciais

As duas funcionalidades leem exatamente as mesmas variáveis de ambiente que qualquer SDK oficial do Langfuse usa. Se você já tem credenciais configuradas para outra ferramenta, elas funcionam aqui sem ajuste nenhum:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
# Só se você não estiver no cloud.langfuse.com:
export LANGFUSE_BASE_URL=https://seu-langfuse-self-hosted.exemplo.com
```

O par de chaves fica nas configurações do seu projeto dentro do Langfuse. Assim que você o define, o export de traces liga na hora, para todos os agentes (mais abaixo tem como gerenciar prompts pelo Langfuse também, ou mandar os traces para outro destino). Se o Langfuse cair ou a chave estiver errada, o export simplesmente descarta o trace em silêncio, e a busca por um `langfuse_prompt` cai de volta para a persona local do agente; nenhum dos dois casos chega a travar uma conversa ou uma execução.

Essas variáveis são lidas direto do processo do Pepe em execução, nunca pela ferramenta `bash` de um agente, algo que importa se um dia você pedir a um agente para ajudar a depurar a conexão. Como `LANGFUSE_PUBLIC_KEY` e `LANGFUSE_SECRET_KEY` têm nome de credencial, o Pepe já as remove por padrão do shell do próprio agente, do mesmo jeito que faz com qualquer outro segredo (veja [Segredos](../secrets/)). Se precisar, o agente ainda pode liberar os dois nomes em `secrets.expose_env` para conferi-las diretamente; só tenha em mente que ler tamanho zero ali quer dizer "removida do meu shell", não "não configurada no servidor".

### Export de traces

Só o par `LANGFUSE_*` já basta: assim que `LANGFUSE_PUBLIC_KEY` e `LANGFUSE_SECRET_KEY` estão definidas, o export liga sozinho, sem precisar de nenhuma variável extra do OTEL. Cada execução concluída vira um trace OTLP completo: um span raiz para a execução inteira, e um span filho para cada chamada de ferramenta e cada chamada de modelo, todos carregando tanto os atributos genéricos do OpenTelemetry quanto os próprios do Langfuse, o que garante que as sessões sejam agrupadas direito e que as gerações apareçam separadas dos spans de ferramenta comuns.

Quer mandar os traces para outro lugar que não o Langfuse, um coletor self-hosted, o Honeycomb, qualquer backend que fale OTLP? Defina as variáveis padrão do OTLP e elas assumem por completo (o par `LANGFUSE_*` passa a servir só para os prompts gerenciados, caso você use isso também):

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://seu-coletor.exemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de usuario:senha>"
```

O detalhe completo, incluindo as duas variáveis extras do OTEL que raramente são necessárias, está em [Traces](../traces/#enviando-traces-para-uma-ferramenta-de-observabilidade).

### Prompts gerenciados

```bash
pepe agent add support --langfuse-prompt support-persona
```

Basta apontar o `langfuse_prompt` de um agente (pela flag do CLI acima, ou pelo mesmo campo no editor de agente do dashboard) para o nome de um prompt no Langfuse, e a persona desse agente passa a vir de lá: edite o prompt no Langfuse e a mudança chega ao Pepe em poucos minutos, sem precisar de redeploy. É opt-in por agente: quem não tem `langfuse_prompt` configurado segue exatamente como sempre foi, e se a busca falhar (servidor fora do ar, nome que não resolve), o agente simplesmente usa a persona local, como se isso nunca tivesse sido configurado. Lê o mesmo par `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` de cima. Detalhe completo em [Agentes](../agents/#gerenciando-uma-persona-pelo-langfuse).
