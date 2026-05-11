---
title: Servidores MCP
description: Conecte servidores do Model Context Protocol para que as ferramentas deles fiquem chamáveis pelos seus agentes.
---

Conecte servidores **MCP (Model Context Protocol)**, como Sentry ou GitHub, e as
ferramentas deles passam a ser chamáveis pelos agentes como se fossem nativas. Os
servidores sobem por stdio sob demanda (via `npx`, então **não há nada para
instalar na mão**), e os tokens entram como referências `${ENV_VAR}`.

## Adicionando um servidor

```bash
pepe mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"
pepe mcp tools sentry     # sobe o servidor e lista as ferramentas (valida a conexão)
pepe mcp list
```

O `pepe mcp tools` realmente sobe o servidor e pergunta o que ele sabe fazer,
então ele serve também como teste de conexão. Um comando errado, um argumento
errado ou um token inválido aparecem ali, e não no meio de uma conversa.

As definições dos servidores ficam em `~/.pepe/config.json`, sob `"mcp"`.

## Como as ferramentas são nomeadas

Cada ferramenta MCP é exposta aos agentes como `mcp__<servidor>__<ferramenta>`. O
nome que você escolheu ao adicionar o servidor é o segmento do meio, então a
mesma ferramenta vinda de dois servidores diferentes nunca colide.

## O escopo é só a lista de ferramentas permitidas

Não existe um segundo modelo de permissão para o MCP. **O escopo é a lista de
ferramentas permitidas do agente.** Para deixar um agente *somente leitura*
contra um servidor, dê a ele apenas as ferramentas de leitura e deixe as de
escrita de fora:

```bash
pepe agent add backoffice --tools read_file,mcp__sentry__find_organizations,mcp__sentry__get_issue
# (sem mcp__sentry__update_issue, então o agente pode olhar, mas não mudar)
```

O curinga `mcp__sentry__*` concede de uma vez todas as ferramentas daquele
servidor.

Ferramentas MCP são arriscadas, então cada chamada continua passando pela
barreira de permissão. A lista de permitidas decide o que o agente pode tentar
usar; a barreira decide se aquela chamada específica acontece.

## Gerenciando servidores pela conversa

Um agente que tenha a ferramenta `manage_mcp` pode adicionar e validar servidores
por conta própria, direto da conversa. Nesse caminho os segredos também
permanecem como referências `${ENV}`, então nada é gravado em disco já expandido.

## Se um token for colado em texto puro

O Pepe já se recusou a salvar um servidor quando detectava um token com cara de
credencial em texto puro. Aquilo parecia responsável e não fazia nada, por causa
de *quando* acontecia: a essa altura o token já tinha sido digitado numa conversa,
ou seja, já tinha ido para o provedor do modelo e já estava na conversa e no trace
em disco. A recusa não desfazia o vazamento. Tudo o que ela conseguia era que o
servidor não fosse adicionado e a pessoa não soubesse por quê.

Então o servidor é salvo, e a resposta diz a verdade: **esse token está
comprometido, revogue e emita outro**, coloque o novo numa variável de ambiente e
refira-se a ele como `${...}`. O `pepe doctor` continua repetindo isso, para quem
não leu da primeira vez. E ele agora também encontra um token guardado sob
qualquer nome com cara de credencial (`GITHUB_TOKEN`, `BRAVE_API_KEY`), coisa que
a checagem antiga, que comparava com uma lista fixa de nomes exatos, passava
batido.

<div class="note"><strong>Segredos ficam como referências.</strong> Escreva um token como <code>${SENTRY_AUTH_TOKEN}</code> e o Pepe o interpola na hora da leitura, sem nunca persistir o valor expandido. O valor vive no ambiente; o <code>~/.pepe/config.json</code> guarda apenas a referência.</div>
