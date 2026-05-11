---
title: Agentes administradores
description: Deixe um agente gerenciar e treinar outros com a ferramenta manage_agent, dentro de um escopo can_manage direcionado.
---

Um agente pode administrar e **treinar outros agentes**. Com a ferramenta `manage_agent`
ele define a persona, o modelo, as ferramentas e a memória de outro agente, ou cria
agentes novos do zero. A autoridade é uma **lista de permissões direcionada, por
agente**, chamada `can_manage`, então você pode ter vários administradores ao mesmo
tempo, cada um com escopo sobre um conjunto diferente de agentes.

## O escopo can_manage

| `can_manage` | O que significa |
|--------------|-----------------|
| ausente, ou `nil` | Apenas ele mesmo. É o padrão. |
| `[]` | Ninguém, nem ele mesmo. Um agente de cliente trancado. |
| `[a, b]` | Exatamente esses agentes. Inclua o próprio nome para incluir a si mesmo. |
| `["*"]` | Todos os agentes. Um superadministrador explícito. |

```bash
# boss passa a administrar o "sales"
pepe agent manage boss sales

# um superadministrador sobre todos os agentes
pepe agent manage boss "*"

# um agente trancado, que não pode alterar a si mesmo
pepe agent add child --can-manage none
```

Assim como no roteamento, `can_manage` é uma lista direcionada e deliberadamente não é
simétrica. Dar ao `boss` autoridade sobre o `sales` não concede ao `sales` nada sobre o
`boss`. A autoridade só flui no sentido em que você a escreveu, e é isso que permite
colocar um agente trancado, voltado ao cliente, na frente de um administrador sem que o
agente de cliente consiga reconfigurar o administrador nem a si mesmo.

## O que o manage_agent faz

| Ação | O que faz |
|------|-----------|
| `list` | Lista os agentes no escopo. |
| `get` | Lê a configuração de um agente. |
| `create` | Cria um agente novo. |
| `set_persona` | Reescreve o prompt de sistema do agente alvo. |
| `set_model` | Aponta o agente alvo para outra conexão de modelo. |
| `set_utility_model` | Define a conexão barata em que rodam as tarefinhas do agente alvo, como dar nome a uma conversa. Um valor vazio desliga isso, e as tarefinhas passam a ser feitas sem modelo. |
| `set_flag` | Liga ou desliga um interruptor do agente alvo (`on`/`off`): `trust_untrusted_content` (deixar que ele aja sobre o que estranhos mandam) ou `exempt_message_limit`. Ligar o `trust_untrusted_content` não pode ser feito a partir de uma execução que ela mesma ingeriu conteúdo de fora, então um documento injetado não consegue virá-lo. |
| `add_tool` | Concede mais uma ferramenta ao agente alvo. |
| `remove_tool` | Revoga uma ferramenta do agente alvo. |
| `remember` | Acrescenta um fato à memória do agente alvo. |

Você não precisa dos nomes técnicos das flags. O `set_flag` é conduzido pelo modelo, então você pede com suas palavras ("deixa o agente de atendimento agir nos arquivos que os clientes mandam", "para de limitar as mensagens desse agente") e ele escolhe o interruptor certo.

A persona e a memória ficam no workspace do agente alvo. As ferramentas e o modelo ficam
na entrada dele no arquivo de configuração.

## A barreira de permissão

`manage_agent` é uma ferramenta de risco, então cada uso dela é autorizado através da
barreira de permissão. O agente propõe a alteração, você aprova, e só então ela é
gravada. Um agente só pode mexer nos agentes dentro do seu próprio escopo `can_manage`,
e um pedido para administrar algo fora desse escopo é recusado.
