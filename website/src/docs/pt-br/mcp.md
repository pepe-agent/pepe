---
title: Servidores MCP
description: Conecte servidores do Model Context Protocol, como GitHub ou Sentry, e as ferramentas prontas deles passam a existir para seus agentes como se fossem nativas.
---

**MCP (Model Context Protocol)** é um jeito padronizado de serviços externos oferecerem ferramentas prontas para agentes de IA, e muitos produtos já publicam o próprio servidor. Conecte um, como Sentry ou GitHub, e as ferramentas dele ficam disponíveis para seus agentes como se tivessem nascido ali dentro. Tokens sempre entram como referência `${ENV_VAR}`.

Um servidor é de um dos dois tipos:

* **Remoto**: uma URL acessada por HTTP. Não roda nada na sua máquina, só precisa do endereço e de uma credencial.
* **Local**: um programa que o próprio Pepe sobe sob demanda e conversa direto com ele (via `npx`, então **não há nada para você instalar na mão**), rodando ao lado do Pepe.

## Adicionando um servidor

```bash
# remoto: um servidor hospedado, acessado por HTTP
pepe mcp add memclaw --url https://memclaw.net/mcp \
  --header "Authorization: Bearer ${MEMCLAW_API_KEY}"

# local: um servidor que o Pepe sobe sozinho
pepe mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"

pepe mcp tools sentry     # conecta e lista as ferramentas dele (valida a conexão)
pepe mcp list
```

O `pepe mcp tools` de fato sobe o servidor e pergunta o que ele sabe fazer, então também funciona como teste de conexão: um comando errado, um argumento errado ou um token inválido aparecem ali na hora, em vez de estourar no meio de uma conversa.

As definições de cada servidor ficam em `~/.pepe/config.json`, dentro de `"mcp"`.

## Servidor remoto: o transporte se resolve sozinho

Um servidor MCP remoto pode conversar de duas formas, e a única maneira de saber qual é tentando: o **Streamable HTTP**, que é o que todo servidor publicado hoje fala, e o par mais antigo **HTTP+SSE**, que alguns ainda não deixaram para trás. O Pepe tenta primeiro o mais novo e cai para o outro se precisar, então você só passa a URL e pronto.

Fixe com `--transport streamable` ou `--transport sse` apenas se essa negociação errar o palpite. E quando erra, tem exatamente a cara de uma URL quebrada, por isso o fallback automático é o padrão, não uma opção que você precisaria conhecer de antemão.

## Entrando num servidor que exige OAuth

Alguns servidores hospedados nem aceitam chave de API, só respondem `401` até você entrar:

```bash
pepe mcp login memclaw
```

O Pepe pergunta ao próprio servidor onde fica seu servidor de autorização, se registra lá como cliente, abre o seu navegador e guarda a concessão resultante. Não tem nada para preencher na mão, nem client id nem endpoint, porque o ponto inteiro dessa etapa de descoberta é que ninguém nunca te contou isso. Por SSH, onde não existe navegador para abrir, ele imprime o link e aceita o código colado de volta.

A concessão se renova sozinha quando expira, e `pepe mcp logout NOME` a esquece. A página de MCP no painel faz esse mesmo login com um botão, e mostra em quais servidores você já está autenticado.

<div class="note"><strong>Tokens não ficam no <code>config.json</code>.</strong> Uma chave estática que você mesmo configura vive no ambiente e é referenciada como <code>${VAR}</code>. Uma concessão OAuth não pode funcionar assim, porque gira sozinha, então ela fica guardada no banco local do Pepe e nunca é escrita no arquivo de configuração.</div>

## Como as ferramentas ganham nome

Cada ferramenta MCP aparece para os agentes como `mcp__<servidor>__<ferramenta>`. O nome que você escolheu ao adicionar o servidor entra como o segmento do meio, então a mesma ferramenta vinda de dois servidores diferentes nunca vai colidir.

## O escopo é simplesmente a lista de ferramentas permitidas

Não existe um segundo modelo de permissão para o MCP: **o escopo é a própria lista de ferramentas permitidas do agente.** Para deixar um agente *somente leitura* diante de um servidor, basta dar a ele só as ferramentas de leitura e deixar as que escrevem de fora:

```bash
pepe agent add backoffice --tools read_file,mcp__sentry__find_organizations,mcp__sentry__get_issue
# (sem mcp__sentry__update_issue, então o agente pode olhar, mas não mudar nada)
```

O curinga `mcp__sentry__*` já libera de uma vez todas as ferramentas daquele servidor.

Ferramentas MCP são arriscadas por natureza, então toda chamada ainda passa pela barreira de permissão. A lista de permitidas decide o que o agente pode tentar; a barreira decide se aquela chamada específica realmente acontece.

## Gerenciando servidores pela própria conversa

Um agente com a ferramenta `manage_mcp` consegue adicionar e validar servidores sozinho, direto do chat. Segredos continuam entrando como referência `${ENV}` nesse caminho também, então nada é gravado em disco já expandido.

## Quando um token é colado em texto puro

O Pepe já se recusou a salvar um servidor quando percebia um token com cara de credencial em texto puro. Parecia responsável, mas na prática não resolvia nada, por causa de *quando* isso acontecia: a essa altura o token já tinha sido digitado numa conversa, ou seja, já tinha ido para o provedor do modelo e já estava tanto na conversa quanto no trace salvo em disco. Recusar não desfazia o vazamento; só garantia que o servidor não fosse adicionado, sem a pessoa nem entender o motivo.

Por isso agora o servidor é salvo, e a resposta conta a verdade: **aquele token está comprometido, revogue e emita outro**, coloque o novo numa variável de ambiente e use `${...}` para referenciá-lo. O `pepe doctor` continua repetindo esse aviso, para quem não leu da primeira vez. E agora ele também identifica um token guardado sob qualquer nome com cara de credencial (`GITHUB_TOKEN`, `BRAVE_API_KEY`), coisa que a checagem antiga, presa a uma lista fixa de nomes exatos, deixava passar direto.

<div class="note"><strong>Segredos ficam só como referência.</strong> Escreva um token como <code>${SENTRY_AUTH_TOKEN}</code> e o Pepe interpola o valor na hora da leitura, sem nunca persistir a versão expandida. O valor mora no ambiente; o <code>~/.pepe/config.json</code> guarda só a referência.</div>
