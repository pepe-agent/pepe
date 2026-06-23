---
title: Gerenciar pela conversa
description: Permita que agentes confiáveis configurem o Pepe em conversas em linguagem natural.
---

Agentes confiáveis podem gerenciar o Pepe pela conversa quando recebem as ferramentas de gestão correspondentes. Essas ações são protegidas porque mudam o estado do runtime ou liberam acesso.

O Pepe foi feito para que um agente consiga resolver um pedido sobre o próprio Pepe, do tipo "adicione um bot", "agende isto", "conecte o Sentry" ou "troque o fuso horário", sem precisar de código sob medida para cada caso e sem nunca ser perigoso. Ele chega lá lendo a própria documentação, descobrindo o que tem permissão de mudar, usando um punhado de ferramentas protegidas para os caminhos mais comuns e verificando o próprio trabalho depois.

## Ele lê a própria documentação

Os guias práticos vêm junto com o Pepe, em `priv/docs/`, e cobrem agentes, canais, cron, MCP, plugins, permissões e configuração. O prompt de sistema de todo agente os lista como a fonte autoritativa, e a ferramenta somente leitura `docs` carrega o guia certo sob demanda. Um pedido novo ou imprevisto é resolvido lendo, não chutando. Coloque guias extras em `~/.pepe/docs/` para estender ou sobrescrever os que vêm de fábrica.

## Ele descobre o que é editável

Chame o `config_set` sem argumento nenhum e ele devolve o próprio schema: os ajustes que pode editar, os valores atuais e os valores aceitos. O conjunto editável é uma lista de permissão que falha fechada, a saber `default_model`, `default_agent`, `language`, `timezone`, `telegram.require_mention` / `telegram.enabled` e `secrets.expose_env` (os *nomes* de variáveis de ambiente que o shell do agente pode manter depois da limpeza, para abrir um cofre para o qual tem um token — só nomes, nunca um valor secreto). Qualquer outra coisa é recusada, com um ponteiro para a ferramenta protegida certa para o trabalho: `manage_agent`, `manage_channel`, `manage_mcp`, `manage_plugin`, `schedule_task` ou `manage_token`. Valores secretos nunca são editáveis pela conversa.

## Administrar agentes

`can_manage` controla quais agentes um agente pode administrar (criar, editar,
reconfigurar, treinar) pela ferramenta `manage_agent`. É fechado por padrão e seu
significado é preciso:

- Sem definir (`null`): o agente pode administrar apenas a si mesmo.
- Vazio (`[]`, definido com `--can-manage none`): ele não pode administrar ninguém,
  nem a si mesmo. Um filho travado, por exemplo um agente voltado ao cliente que não
  pode se alterar.
- Uma lista de nomes: exatamente esses agentes, e nenhum outro. Inclua o próprio nome
  para deixar que ele também administre a si mesmo.
- `["*"]` (definido com `--can-manage "*"`): todos os agentes. Um superadministrador
  explícito.

Conceda autoridade de gestão diretamente:

```bash
pepe agent manage supervisor "*"
```

### Faça pela conversa

Um agente administrador usa `manage_agent` para moldar os agentes do seu escopo. Suas
ações são `list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`,
`remove_tool` e `remember` (anexa um fato duradouro à memória do alvo). Por exemplo:

```text
Dê ao agente de suporte a ferramenta send_file e registre na memória dele que
reembolsos acima de 200 precisam de uma pessoa.
```

O agente chama `manage_agent` com `action: "add_tool"` e depois com
`action: "remember"`. Cada uma dessas ações tem barreira: o agente propõe a mudança,
você a autoriza e só então ela é aplicada. Um agente também pode se renomear com a
ferramenta separada `rename_agent` ("De agora em diante, se chame scout"), que move o
diretório do seu workspace e entra em vigor na próxima mensagem.

## Instalar plugins da comunidade

A ferramenta protegida `manage_plugin` instala, escaneia, lista e remove ferramentas e canais `.exs` avulsos pela conversa. Ela aceita um caminho local, um `.tar.gz` ou uma URL do GitHub, e toda instalação passa pela mesma varredura estática que a CLI usa.

Diferente da CLI, essa ferramenta não tem `--force`. Um veredito `danger` da varredura é sempre recusado pela conversa. Passar por cima de um veredito perigoso é uma decisão de operador, tomada de forma deliberada no terminal, e nunca uma decisão à qual um agente possa ser convencido no meio de um papo.

## Liberar acesso à API

A ferramenta protegida `manage_token` gera, lista e revoga tokens de portador do `/v1` pela conversa, com escopo de um projeto ou de um único agente. Assim um agente consegue dar acesso a uma integração sem que você precise ir até um terminal. Como as outras ferramentas de gestão, ela não é somente leitura, então passa antes pela barreira de permissão.

## O dono pode rodar a CLI inteira

Para um agente dono em quem você confia plenamente, o `manage_pepe` roda qualquer comando `pepe` não interativo pela conversa, pelo mesmo despachante que a CLI usa. Comandos interativos e bloqueantes (`setup`, `chat`, `serve` e os gateways em primeiro plano) são recusados, e a ferramenta continua atrás da barreira de permissão. Dê-a apenas a um agente dono confiável, nunca a um exposto a entradas não confiáveis. Veja [Segurança e ambiente isolado](../security/) para os detalhes.

## Ele verifica o próprio trabalho

Depois de mudar alguma coisa, o agente (ou você) roda o doctor. Ele faz verificações offline, conferindo que toda referência `${ENV}` resolve, que os agentes apontam para modelos reais e ferramentas conhecidas, e que os agendamentos, fusos horários e agentes do cron são válidos. Ele também faz sondagens ao vivo: um `getMe` do Telegram por bot, um ping por conexão de modelo, e um start do MCP mais a listagem de ferramentas por servidor.

```bash
pepe doctor              # sondagens ao vivo (Telegram, modelos, MCP)
pepe doctor --offline    # só a consistência da configuração, sem rede
```

O ciclo é fazer, verificar, corrigir: ferramentas protegidas e estruturadas para os caminhos mais comuns, ferramentas genéricas mais a documentação para todo o resto, e o doctor para confirmar que funcionou.
