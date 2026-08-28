---
title: Agentes administradores
description: Com a ferramenta manage_agent, um agente treina e gerencia outros dentro de um escopo can_manage direcionado.
---

Um agente pode administrar e **treinar outros agentes**: a ferramenta `manage_agent` deixa
ele definir a persona, o modelo, as ferramentas e a memória de outro agente, ou criar
agentes novos do zero. Essa autoridade vem de uma **lista de permissões direcionada, por
agente**, chamada `can_manage`, o que permite manter vários administradores ao mesmo
tempo, cada um respondendo por um conjunto diferente de agentes.

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

Assim como o roteamento entre agentes, `can_manage` é direcionado, e de propósito não é
uma via de mão dupla: dar ao `boss` autoridade sobre o `sales` não devolve ao `sales`
nada sobre o `boss`. A autoridade corre só no sentido em que foi escrita, e é exatamente
isso que permite pôr um agente trancado, voltado ao cliente, na frente de um
administrador sem correr o risco de esse agente reconfigurar o administrador, ou a si
mesmo.

## O que o manage_agent faz

| Ação | O que faz |
|------|-----------|
| `list` | Lista os agentes dentro do escopo. |
| `get` | Lê a configuração de um agente. |
| `create` | Cria um agente novo. |
| `set_persona` | Reescreve o prompt de sistema do agente alvo. |
| `set_model` | Aponta o agente alvo para outra conexão de modelo. |
| `set_utility_model` | Define a conexão barata em que rodam as tarefinhas do agente alvo, como dar nome a uma conversa. Deixar vazio desliga isso, e as tarefinhas passam a acontecer sem modelo nenhum. |
| `set_flag` | Liga ou desliga (`on`/`off`) um interruptor do agente alvo: `trust_untrusted_content` (deixar que ele aja sobre o que estranhos mandam), `exempt_message_limit`, `midrun_fold` (deixar uma correção no meio do turno redirecionar o turno em andamento, em vez de sempre esperar o próximo; usa o `triage_model`, se houver, senão o próprio modelo do agente, ao custo de uma chamada extra por mensagem no meio do turno), `commitments` (perceber sozinho um follow-up prometido ao fim de cada turno e passar a acompanhá-lo), `session_search_project_wide` (deixar o `session_search` enxergar todas as conversas do projeto do agente alvo, não só as do chamador; veja [Busca de sessões](../session-search/) — desligado é o certo para um agente que atende vários clientes finais diferentes), ou `capability_nudge` (deixar que ele mencione, numa frase curta logo após ajudar com algo, uma funcionalidade relacionada que realmente se aplique: Watches, tarefas agendadas, Goals, uma skill instalada). Ligar `trust_untrusted_content` ou `session_search_project_wide` é algo que não pode partir de uma execução que ela mesma já ingeriu conteúdo externo, então um documento injetado nunca consegue virar nenhum dos dois sozinho. |
| `add_tool` | Concede mais uma ferramenta ao agente alvo. |
| `remove_tool` | Revoga uma ferramenta do agente alvo. |
| `remember` | Acrescenta um fato à memória do agente alvo. |

Você não precisa saber o nome técnico de cada flag: o `set_flag` é conduzido pelo
próprio modelo, então basta pedir com suas palavras ("deixa o agente de atendimento
agir nos arquivos que os clientes mandam", "para de limitar as mensagens desse
agente") que ele acha o interruptor certo.

A persona e a memória moram no workspace do agente alvo. As ferramentas e o modelo
ficam na entrada dele dentro do arquivo de configuração.

## A barreira de permissão

Como `manage_agent` é uma ferramenta de risco, todo uso dela passa pela barreira de
permissão: o agente propõe a mudança, você aprova, e só depois disso ela é gravada. Um
agente só consegue mexer nos agentes que estão dentro do próprio escopo `can_manage`, e
um pedido para administrar algo fora desse escopo é recusado de cara.
