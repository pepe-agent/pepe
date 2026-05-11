---
title: Agentes administradores
description: Deixa um agente gerir e treinar outros com a ferramenta manage_agent, dentro de um âmbito can_manage dirigido.
---

Um agente pode administrar e **treinar outros agentes**. Com a ferramenta `manage_agent`
define a persona, o modelo, as ferramentas e a memória de outro agente, ou cria agentes
novos de raiz. A autoridade é uma **lista de permissões dirigida, por agente**, chamada
`can_manage`, por isso podes ter vários administradores ao mesmo tempo, cada um com
âmbito sobre um conjunto diferente de agentes.

## O âmbito can_manage

| `can_manage` | O que significa |
|--------------|-----------------|
| ausente, ou `nil` | Apenas ele próprio. É o valor por omissão. |
| `[]` | Ninguém, nem sequer ele próprio. Um agente de cliente trancado. |
| `[a, b]` | Exatamente esses agentes. Inclui o próprio nome para o incluir a ele. |
| `["*"]` | Todos os agentes. Um superadministrador explícito. |

```bash
# boss passa a administrar o "sales"
pepe agent manage boss sales

# um superadministrador sobre todos os agentes
pepe agent manage boss "*"

# um agente trancado, que não pode alterar-se a si próprio
pepe agent add child --can-manage none
```

Tal como no encaminhamento, `can_manage` é uma lista dirigida e deliberadamente não é
simétrica. Dar ao `boss` autoridade sobre o `sales` não concede ao `sales` nada sobre o
`boss`. A autoridade só flui no sentido em que a escreveste, e é isso que te permite
colocar um agente trancado, virado para o cliente, à frente de um administrador sem que o
agente de cliente consiga reconfigurar o administrador nem a si próprio.

## O que o manage_agent faz

| Ação | O que faz |
|------|-----------|
| `list` | Lista os agentes no âmbito. |
| `get` | Lê a configuração de um agente. |
| `create` | Cria um agente novo. |
| `set_persona` | Reescreve o prompt de sistema do agente alvo. |
| `set_model` | Aponta o agente alvo para outra ligação de modelo. |
| `set_utility_model` | Define a ligação barata onde correm as tarefas menores do agente alvo, como dar nome a uma conversa. Um valor vazio desliga isto, e as tarefas passam a ser feitas sem modelo. |
| `add_tool` | Concede mais uma ferramenta ao agente alvo. |
| `remove_tool` | Revoga uma ferramenta do agente alvo. |
| `remember` | Acrescenta um facto à memória do agente alvo. |

A persona e a memória vivem no workspace do agente alvo. As ferramentas e o modelo vivem
na entrada dele no ficheiro de configuração.

## A barreira de permissão

`manage_agent` é uma ferramenta de risco, por isso cada utilização é autorizada através
da barreira de permissão. O agente propõe a alteração, tu aprovas, e só então ela é
escrita. Um agente só pode mexer nos agentes dentro do seu próprio âmbito `can_manage`, e
um pedido para administrar algo fora desse âmbito é recusado.
