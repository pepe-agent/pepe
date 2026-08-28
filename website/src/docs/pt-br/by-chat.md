---
title: Gerenciar pela conversa
description: Dê a agentes de confiança as ferramentas para configurar o Pepe a partir de conversas em linguagem natural.
---

Basta pedir a um agente para reconfigurar o Pepe, uma vez que você dê a um
agente de confiança as ferramentas de gestão correspondentes. Essas ações vêm
protegidas: como mudam o funcionamento do Pepe ou liberam acesso, sempre pedem
sua aprovação antes de valer.

O Pepe foi construído para que um agente consiga resolver sozinho um pedido
sobre o próprio Pepe (algo como "adicione um bot", "agende isto", "conecte o
Sentry" ou "troque o fuso horário"), sem precisar de tratamento especial para
cada caso e sem nunca virar perigoso. Ele chega lá de três formas: lendo a
própria documentação, descobrindo o que tem permissão de mudar, recorrendo a um
punhado de ferramentas protegidas para os caminhos mais comuns, e verificando
o próprio trabalho depois de feito.

## Ele lê a própria documentação

Os guias práticos já vêm junto com o Pepe, em `priv/docs/`, cobrindo agentes,
canais, cron, MCP, plugins, permissões e configuração. O prompt de sistema de
todo agente os lista como a fonte oficial, e a ferramenta somente leitura
`docs` carrega o guia certo sob demanda. Um pedido novo ou imprevisto é
resolvido lendo, nunca chutando. Para estender ou sobrescrever os guias que já
vêm de fábrica, basta colocar guias extras em `~/.pepe/docs/`.

## Ele descobre o que é editável

Chame `config_set` sem nenhum argumento e ele devolve o próprio schema: os
ajustes que pode editar, os valores atuais deles e os valores aceitos. Esse
conjunto editável é uma lista curta e fixa: `default_model`, `default_agent`,
`language`, `timezone`, `telegram.require_mention` / `telegram.enabled` e
`secrets.expose_env` (os *nomes* das variáveis de ambiente que o shell do
agente pode manter depois que o Pepe limpa o resto, para abrir um cofre para o
qual ele já tem um token; só os nomes, nunca o valor de um segredo). Tudo o
que fica fora dessa lista é recusado, com uma indicação da ferramenta
protegida certa para o trabalho: `manage_agent`, `manage_channel`,
`manage_mcp`, `manage_plugin`, `schedule_task` ou `manage_token`. Valores de
segredos nunca são editáveis pela conversa.

## Administrar agentes

`can_manage` controla quais agentes um agente pode administrar (criar, editar,
reconfigurar, treinar) pela ferramenta `manage_agent`. Vem fechado por padrão,
e o significado é preciso:

- Sem definir (`null`): o agente pode administrar só a si mesmo.
- Vazio (`[]`, definido com `--can-manage none`): não pode administrar
  ninguém, nem a si mesmo. Um filho trancado, por exemplo um agente voltado ao
  cliente que não pode se alterar.
- Uma lista de nomes: exatamente esses agentes, e mais nenhum. Inclua o
  próprio nome se quiser que ele também administre a si mesmo.
- `["*"]` (definido com `--can-manage "*"`): todos os agentes. Um
  superadministrador explícito.

Conceda autoridade de gestão diretamente:

```bash
pepe agent manage supervisor "*"
```

### Faça pela conversa

Um agente administrador usa o `manage_agent` para moldar os agentes do seu
escopo. As ações dele são `list`, `get`, `create`, `set_persona`, `set_model`,
`add_tool`, `remove_tool` e `remember` (que anexa um fato duradouro à memória
do alvo). Por exemplo:

```text
Dê ao agente de suporte a ferramenta send_file e registre na memória dele que
reembolsos acima de 200 precisam de uma pessoa.
```

O agente chama `manage_agent` com `action: "add_tool"` e depois com
`action: "remember"`. Cada uma dessas ações tem barreira própria: o agente
propõe a mudança, você a autoriza, e só então ela é aplicada. Um agente também
pode se renomear com a ferramenta separada `rename_agent` ("De agora em
diante, se chame scout"), que move o diretório do seu workspace e entra em
vigor na próxima mensagem.

## Instalar plugins da comunidade

A ferramenta protegida `manage_plugin` instala, escaneia, lista e remove
ferramentas e canais `.exs` avulsos direto pela conversa. Ela aceita um
caminho local, um `.tar.gz` ou uma URL do GitHub, e toda instalação passa pela
mesma varredura estática que a CLI já usa.

Diferente da CLI, essa ferramenta não tem `--force`: um veredito `danger` da
varredura é sempre recusado quando vem pela conversa. Passar por cima de um
veredito perigoso é uma decisão de operador, tomada de propósito no terminal,
e nunca algo para o qual um agente possa ser convencido no meio de um papo.

## Liberar acesso à API

A ferramenta protegida `manage_token` gera, lista e revoga tokens de portador
do `/v1` direto pela conversa, com escopo de um projeto ou de um único agente.
Assim, um agente consegue dar acesso a uma integração sem que você precise ir
até um terminal. Como as outras ferramentas de gestão, ela não é somente
leitura, então passa antes pela barreira de permissão.

## O dono pode rodar a CLI inteira

Para um agente dono em quem você confia plenamente, o `manage_pepe` roda
qualquer comando `pepe` não interativo direto pela conversa, pelo mesmo
despachante que a própria CLI usa. Comandos interativos e bloqueantes
(`setup`, `chat`, `serve` e os gateways em primeiro plano) são recusados, e a
ferramenta continua atrás da barreira de permissão. Dê essa ferramenta só a um
agente dono de confiança, nunca a um exposto a entradas não confiáveis. Veja
[Segurança e ambiente isolado](../security/) para os detalhes.

## Ele verifica o próprio trabalho

Depois de mudar alguma coisa, o agente (ou você) roda o doctor. Ele faz
verificações offline, conferindo que toda referência `${ENV}` resolve, que os
agentes apontam para modelos reais e ferramentas conhecidas, e que os
agendamentos, fusos horários e agentes do cron são válidos. Além disso, ele
roda sondagens ao vivo: um `getMe` do Telegram por bot, um ping por conexão de
modelo, e um start do MCP mais a listagem de ferramentas por servidor.

```bash
pepe doctor              # sondagens ao vivo (Telegram, modelos, MCP)
pepe doctor --offline    # só a consistência da configuração, sem rede
```

O ciclo é sempre o mesmo: fazer, verificar, corrigir. Ferramentas protegidas e
estruturadas para os caminhos mais comuns, ferramentas genéricas mais a
documentação para todo o resto, e o doctor confirmando no final que tudo
funcionou.
