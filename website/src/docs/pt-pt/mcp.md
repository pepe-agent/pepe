---
title: Servidores MCP
description: Liga servidores do Model Context Protocol para que as ferramentas deles fiquem ao alcance dos teus agentes.
---

Liga servidores **MCP (Model Context Protocol)**, como o Sentry ou o GitHub, e as
ferramentas deles passam a poder ser chamadas pelos agentes como se fossem
nativas. Os servidores arrancam por stdio a pedido (através do `npx`, por isso
**não há nada para instalar à mão**), e os tokens entram como referências
`${ENV_VAR}`.

## Adicionar um servidor

```bash
pepe mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"
pepe mcp tools sentry     # arranca o servidor e lista as ferramentas (valida a ligação)
pepe mcp list
```

O `pepe mcp tools` arranca mesmo o servidor e pergunta-lhe o que sabe fazer, por
isso também serve de teste de ligação. Um comando errado, um argumento errado ou
um token inválido aparecem aí, e não a meio de uma conversa.

As definições dos servidores ficam em `~/.pepe/config.json`, sob `"mcp"`.

## Como as ferramentas são nomeadas

Cada ferramenta MCP é exposta aos agentes como `mcp__<servidor>__<ferramenta>`. O
nome que escolheste ao adicionar o servidor é o segmento do meio, por isso a mesma
ferramenta vinda de dois servidores diferentes nunca colide.

## O âmbito é apenas a lista de ferramentas permitidas

Não existe um segundo modelo de permissões para o MCP. **O âmbito é a lista de
ferramentas permitidas do agente.** Para deixar um agente *só de leitura* perante
um servidor, dá-lhe apenas as ferramentas de leitura e deixa as de escrita de
fora:

```bash
pepe agent add backoffice --tools read_file,mcp__sentry__find_organizations,mcp__sentry__get_issue
# (sem mcp__sentry__update_issue, por isso o agente pode ver, mas não alterar)
```

O carácter universal `mcp__sentry__*` concede de uma só vez todas as ferramentas
daquele servidor.

As ferramentas MCP são arriscadas, por isso cada chamada continua a passar pela
barreira de permissão. A lista de permitidas decide aquilo que o agente pode
tentar usar; a barreira decide se aquela chamada em concreto avança.

## Gerir servidores pela conversa

Um agente que tenha a ferramenta `manage_mcp` consegue adicionar e validar
servidores por si próprio, a partir de uma conversa. Também nesse caminho os
segredos se mantêm como referências `${ENV}`, por isso nada é escrito em disco já
expandido.

## Se um token for colado em texto simples

O Pepe recusava-se a guardar um servidor quando detetava um token em texto
simples. Aquilo parecia responsável e não fazia nada, por causa de *quando*
acontecia: nessa altura o token já tinha sido escrito numa conversa, ou seja, já
tinha ido para o fornecedor do modelo e já estava na conversa e no trace em disco.
A recusa não desfazia a fuga. Só conseguia que o servidor não fosse adicionado e
que a pessoa não percebesse porquê.

Por isso o servidor é guardado, e a resposta diz a verdade: **esse token está
comprometido, revoga-o e emite outro**, põe o novo numa variável de ambiente e
refere-te a ele como `${...}`. O `pepe doctor` continua a repeti-lo, para quem não
leu à primeira. E agora também encontra um token arquivado sob qualquer nome com
ar de credencial (`GITHUB_TOKEN`, `BRAVE_API_KEY`), coisa que a verificação
antiga, que comparava com uma lista fixa de nomes exatos, deixava passar.

<div class="note"><strong>Os segredos mantêm-se como referências.</strong> Escreve um token como <code>${SENTRY_AUTH_TOKEN}</code> e o Pepe interpola-o no momento da leitura, sem nunca persistir o valor expandido. O valor vive no ambiente; o <code>~/.pepe/config.json</code> guarda apenas a referência.</div>
