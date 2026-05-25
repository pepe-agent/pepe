---
title: Gerir pela conversa
description: Permite que agentes de confiança configurem o Pepe em conversas em linguagem natural.
---

Agentes de confiança podem gerir o Pepe pela conversa quando recebem as ferramentas de gestão correspondentes. Estas ações são protegidas porque alteram o estado do runtime ou libertam acesso.

O Pepe foi feito para que um agente consiga resolver um pedido sobre o próprio Pepe, do género "acrescenta um bot", "agenda isto", "liga o Sentry" ou "muda o fuso horário", sem código à medida para cada caso e sem nunca ser perigoso. Chega lá lendo a sua própria documentação, descobrindo o que tem permissão para alterar, usando um punhado de ferramentas protegidas para os caminhos mais comuns e verificando o próprio trabalho no fim.

## Lê a sua própria documentação

Os guias práticos vêm com o Pepe, em `priv/docs/`, e cobrem agentes, canais, cron, MCP, plugins, permissões e configuração. O prompt de sistema de cada agente lista-os como a fonte autoritativa, e a ferramenta de leitura apenas `docs` carrega o guia certo a pedido. Um pedido novo ou imprevisto resolve-se a ler, não a adivinhar. Coloca guias adicionais em `~/.pepe/docs/` para estender ou substituir os que vêm de origem.

## Descobre o que é editável

Chama o `config_set` sem argumento nenhum e ele devolve o seu próprio schema: as definições que pode editar, os valores atuais e os valores aceites. O conjunto editável é uma lista de permissões que falha fechada, a saber `default_model`, `default_agent`, `language`, `timezone` e `telegram.require_mention` / `telegram.enabled`. Tudo o resto é recusado, com uma indicação da ferramenta protegida certa para a tarefa: `manage_agent`, `manage_channel`, `manage_mcp`, `manage_plugin`, `schedule_task` ou `manage_token`. Os segredos nunca são editáveis pela conversa.

## Administrar agentes

`can_manage` controla que agentes um agente pode administrar (criar, editar,
reconfigurar, treinar) através da ferramenta `manage_agent`. É fechado por
predefinição e o seu significado é preciso:

- Por definir (`null`): o agente só pode administrar-se a si próprio.
- Vazio (`[]`, definido com `--can-manage none`): não pode administrar ninguém, nem
  sequer a si próprio. Um filho bloqueado, por exemplo um agente virado para o
  cliente que não se deve alterar.
- Uma lista de nomes: exatamente esses agentes, e mais nenhum. Inclui o próprio nome
  para o deixar administrar-se também a si próprio.
- `["*"]` (definido com `--can-manage "*"`): todos os agentes. Um superadministrador
  explícito.

Concede autoridade de gestão diretamente:

```bash
pepe agent manage supervisor "*"
```

### Fá-lo pela conversa

Um agente administrador usa `manage_agent` para moldar os agentes do seu âmbito. As
suas ações são `list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`,
`remove_tool` e `remember` (acrescenta um facto duradouro à memória do alvo). Por
exemplo:

```text
Dá ao agente de apoio a ferramenta send_file e regista na memória dele que
reembolsos acima de 200 precisam de uma pessoa.
```

O agente chama `manage_agent` com `action: "add_tool"` e depois com
`action: "remember"`. Cada uma destas ações tem barreira: o agente propõe a
alteração, tu autoriza-la e só então é aplicada. Um agente também se pode renomear
com a ferramenta separada `rename_agent` ("De agora em diante, chama-te scout"), que
move o diretório do seu workspace e entra em vigor na próxima mensagem.

## Instalar plugins da comunidade

A ferramenta protegida `manage_plugin` instala, analisa, lista e remove ferramentas e canais `.exs` avulsos pela conversa. Aceita um caminho local, um `.tar.gz` ou um URL do GitHub, e cada instalação passa pela mesma análise estática que a CLI usa.

Ao contrário da CLI, esta ferramenta não tem `--force`. Um veredicto `danger` da análise é sempre recusado pela conversa. Ignorar um veredicto perigoso é uma decisão de operador, tomada deliberadamente no terminal, e nunca uma decisão em que um agente possa ser enrolado a meio de uma conversa.

## Libertar acesso à API

A ferramenta protegida `manage_token` gera, lista e revoga tokens de portador do `/v1` pela conversa, com âmbito de um projeto ou de um único agente. Assim um agente consegue dar acesso a uma integração sem que tenhas de ir a um terminal. Tal como as outras ferramentas de gestão, não é de leitura apenas, por isso passa primeiro pela barreira de permissão.

## O proprietário pode correr a CLI inteira

Para um agente proprietário em quem confies totalmente, o `manage_pepe` executa qualquer comando `pepe` não interativo pela conversa, através do mesmo despachante que a CLI usa. Os comandos interativos e bloqueantes (`setup`, `chat`, `serve` e os gateways em primeiro plano) são recusados, e a ferramenta continua atrás da barreira de permissão. Concede-a apenas a um agente proprietário de confiança, nunca a um exposto a entradas não fidedignas. Vê [Segurança e ambiente isolado](../security/) para os detalhes.

## Verifica o seu próprio trabalho

Depois de alterar alguma coisa, o agente (ou tu) corre o doctor. Ele faz verificações offline, confirmando que cada referência `${ENV}` se resolve, que os agentes apontam para modelos reais e ferramentas conhecidas, e que os agendamentos, fusos horários e agentes do cron são válidos. Faz também sondagens em direto: um `getMe` do Telegram por bot, um ping por ligação de modelo, e um arranque do MCP mais a listagem de ferramentas por servidor.

```bash
pepe doctor              # sondagens em direto (Telegram, modelos, MCP)
pepe doctor --offline    # só a consistência da configuração, sem rede
```

O ciclo é fazer, verificar, corrigir: ferramentas protegidas e estruturadas para os caminhos mais comuns, ferramentas genéricas mais a documentação para todo o resto, e o doctor para confirmar que resultou.
