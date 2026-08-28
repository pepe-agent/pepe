---
title: Servidores MCP
description: Liga servidores do Model Context Protocol, como o GitHub ou o Sentry, e as ferramentas deles ficam logo disponíveis para os teus agentes.
---

O **MCP (Model Context Protocol)** é uma forma padrão de um serviço externo oferecer ferramentas já prontas a agentes de IA, e há muitos produtos que publicam uma. Liga um servidor MCP, o Sentry ou o GitHub por exemplo, e as ferramentas dele tornam-se chamáveis pelos teus agentes tal como se fossem nativas. Os tokens entram sempre como referências `${ENV_VAR}`.

Um servidor é sempre de um destes dois tipos:

* **Remoto**: um URL alcançável por HTTP. Não corre nada na tua máquina, só precisas do endereço e de uma credencial.
* **Local**: um programa que o Pepe arranca a pedido e com o qual fala diretamente (através do `npx`, por isso **não há nada para instalares à mão**), correndo ao lado do Pepe.

## Adicionar um servidor

```bash
# remoto: um servidor alojado, alcançado por HTTP
pepe mcp add memclaw --url https://memclaw.net/mcp \
  --header "Authorization: Bearer ${MEMCLAW_API_KEY}"

# local: um servidor que o próprio Pepe arranca
pepe mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"

pepe mcp tools sentry     # liga-se e lista as suas ferramentas (valida a ligação)
pepe mcp list
```

O `pepe mcp tools` arranca mesmo o servidor e pergunta-lhe o que sabe fazer, por isso funciona também como teste de ligação: um comando errado, um argumento trocado ou um token inválido aparecem logo aí, em vez de te surpreenderem a meio de uma conversa.

As definições dos servidores ficam guardadas em `~/.pepe/config.json`, dentro de `"mcp"`.

## Servidores remotos: o transporte escolhe-se sozinho

Há duas formas de um servidor MCP remoto falar, e a única maneira de as distinguir é experimentando: o **Streamable HTTP**, que é o que um servidor publicado hoje em dia usa, e o par mais antigo **HTTP+SSE**, do qual alguns ainda não migraram. O Pepe tenta primeiro o mais recente e recua para o outro se for preciso, por isso basta dares-lhe o URL e nada mais.

Só vale a pena fixar com `--transport streamable` ou `--transport sse` se a negociação automática falhar. E quando falha, o sintoma é indistinguível de um URL errado, razão pela qual o recuo automático é o comportamento por omissão, em vez de uma opção que terias de conhecer de antemão.

## Iniciar sessão num servidor que exige OAuth

Alguns servidores alojados não aceitam nenhuma chave de API e respondem sempre `401` até iniciares sessão:

```bash
pepe mcp login memclaw
```

O Pepe pergunta ao próprio servidor onde fica o seu servidor de autorização, regista-se aí como cliente, abre-te o navegador e guarda a concessão obtida. Não há nada para preenches à mão, nem um client id nem um endpoint, precisamente porque a razão de existir esse passo de descoberta é nunca te terem dito nada disso à partida. Por SSH, onde não há navegador para abrir, o Pepe imprime a ligação e aceita antes o código que colares.

A concessão renova-se sozinha quando expira, e `pepe mcp logout NOME` esquece-a quando quiseres. A página de MCP no painel oferece o mesmo início de sessão através de um botão, e mostra em que servidores já entraste.

<div class="note"><strong>Os tokens não ficam no <code>config.json</code>.</strong> Uma chave estática que tu próprio configuras vive no ambiente e é referenciada como <code>${VAR}</code>. Uma concessão OAuth não pode funcionar assim, porque roda sozinha, por isso fica guardada na base de dados local do Pepe, e nunca é escrita no ficheiro de configuração.</div>

## Como as ferramentas ficam com nome

Cada ferramenta MCP é exposta aos agentes como `mcp__<servidor>__<ferramenta>`. O nome que escolheste ao adicionares o servidor entra no segmento do meio, o que garante que a mesma ferramenta vinda de dois servidores diferentes nunca colide.

## O âmbito não é mais do que a lista de ferramentas permitidas

Não existe um segundo modelo de permissões próprio do MCP: **o âmbito é a lista de ferramentas permitidas do agente**, sem mais. Para deixares um agente *só de leitura* perante um servidor, dá-lhe apenas as ferramentas de leitura e fica de fora com as que alteram algo:

```bash
pepe agent add backoffice --tools read_file,mcp__sentry__find_organizations,mcp__sentry__get_issue
# (sem mcp__sentry__update_issue, para que o agente possa ver, mas não alterar)
```

O caractere universal `mcp__sentry__*` concede de uma só vez todas as ferramentas daquele servidor.

Como as ferramentas MCP são arriscadas, cada chamada continua a passar pela barreira de permissão: a lista de permitidas decide o que o agente pode sequer tentar, e é a barreira que decide se esta chamada em particular avança ou não.

## Gerir servidores pela conversa

Um agente com a ferramenta `manage_mcp` consegue adicionar e validar servidores por conta própria, direto de uma conversa. Também por este caminho os segredos ficam como referências `${ENV}`, por isso nunca nada é escrito em disco já expandido.

## Se um token acabar colado em texto simples

O Pepe costumava recusar-se a guardar um servidor sempre que detetava um token em texto simples. Parecia uma atitude responsável, mas na prática não resolvia nada, por causa do *momento* em que acontecia: a essa altura o token já tinha sido escrito numa conversa, ou seja, já tinha ido parar ao fornecedor do modelo e já estava gravado tanto na conversa como no trace em disco. A recusa não desfazia a fuga; conseguia apenas que o servidor não ficasse adicionado, e a pessoa nem sequer percebia porquê.

Por isso agora o servidor é guardado na mesma, e a resposta diz a verdade como ela é: **esse token está comprometido, revoga-o e emite outro**, guarda o novo numa variável de ambiente e passa a referir-te a ele como `${...}`. O `pepe doctor` continua a repetir este aviso, para quem não o tiver lido à primeira. E agora também apanha um token escondido sob qualquer nome com cara de credencial (`GITHUB_TOKEN`, `BRAVE_API_KEY`), coisa que a verificação antiga, que só comparava com uma lista fixa de nomes exatos, deixava passar direitinho.

<div class="note"><strong>Os segredos mantêm-se sempre como referências.</strong> Escreve um token como <code>${SENTRY_AUTH_TOKEN}</code> e o Pepe interpola-o no momento da leitura, sem nunca guardar o valor já expandido. O valor propriamente dito vive no ambiente; o <code>~/.pepe/config.json</code> guarda só a referência a ele.</div>
