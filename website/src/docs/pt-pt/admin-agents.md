---
title: Agentes administradores
description: Um agente pode gerir e treinar outros através da ferramenta manage_agent, com o âmbito definido por uma lista dirigida can_manage.
---

Um agente pode administrar e **treinar outros agentes**: com a ferramenta `manage_agent`
consegue definir a persona, o modelo, as ferramentas e a memória de outro agente, ou até
criar agentes novos de raiz. Quem tem autoridade sobre quem é decidido por uma **lista de
permissões dirigida, por agente**, chamada `can_manage`. Isto torna possível ter vários
administradores ativos ao mesmo tempo, cada um limitado a um conjunto diferente de agentes.

## O âmbito de can_manage

| `can_manage` | O que significa |
|--------------|-----------------|
| ausente, ou `nil` | Só a si próprio. É o valor por omissão. |
| `[]` | Ninguém, nem sequer o próprio agente. Um agente de cliente completamente trancado. |
| `[a, b]` | Só esses agentes, exatamente. Para se incluir a ele próprio, tem de pôr lá o seu nome. |
| `["*"]` | Todos os agentes. Um superadministrador explícito. |

```bash
# boss passa a administrar o "sales"
pepe agent manage boss sales

# um superadministrador sobre todos os agentes
pepe agent manage boss "*"

# um agente trancado, incapaz de se alterar a si próprio
pepe agent add child --can-manage none
```

À semelhança do encaminhamento, o `can_manage` é uma lista dirigida e não é simétrica de
propósito: dar ao `boss` autoridade sobre o `sales` não dá ao `sales` autoridade nenhuma
sobre o `boss`. A autoridade corre apenas no sentido que escreveste, o que abre a
possibilidade de pôr um agente trancado e virado para o cliente à frente de um
administrador, sem que esse agente de cliente consiga alguma vez reconfigurar o
administrador, nem a si mesmo.

## O que o manage_agent consegue fazer

| Ação | O que faz |
|------|-----------|
| `list` | Lista os agentes dentro do âmbito. |
| `get` | Lê a configuração de um agente. |
| `create` | Cria um agente novo. |
| `set_persona` | Reescreve o prompt de sistema do agente alvo. |
| `set_model` | Muda a ligação de modelo a que o agente alvo está associado. |
| `set_utility_model` | Define a ligação barata usada para as tarefas menores do agente alvo, como dar um nome a uma conversa. Um valor vazio desativa isto, e essas tarefas passam a ser resolvidas sem recorrer a nenhum modelo. |
| `set_flag` | Liga ou desliga um interruptor do agente alvo (`on`/`off`). Os interruptores disponíveis são: `trust_untrusted_content` (permite-lhe agir sobre conteúdo enviado por estranhos), `exempt_message_limit`, `midrun_fold` (permite que uma correção a meio de um turno redirecione esse turno em vez de ficar sempre à espera; usa o `triage_model` quando este existe, ou o próprio modelo do agente caso contrário, ao custo de uma chamada extra por cada mensagem recebida a meio do turno), `commitments` (repara sozinho num seguimento que o agente prometeu no fim de cada turno e passa a acompanhá-lo, sem que lhe seja pedido), `session_search_project_wide` (deixa o `session_search` ver todas as conversas do projeto do agente alvo, não só as do próprio chamador; consulta [Busca de sessões](../session-search/) para mais detalhe. Manter desligado é a escolha certa para um agente que fala com vários clientes finais distintos) e `capability_nudge` (deixa-o mencionar, numa frase curta, uma funcionalidade relacionada, como Watches, tarefas agendadas, Goals ou uma skill instalada, logo a seguir a ajudar com algo, sempre que essa funcionalidade realmente se aplicar). Nem `trust_untrusted_content` nem `session_search_project_wide` podem ser ligados a partir de uma execução que já tenha, ela própria, absorvido conteúdo externo, de forma a que um documento injetado nunca consiga ativar nenhum dos dois. |
| `add_tool` | Concede mais uma ferramenta ao agente alvo. |
| `remove_tool` | Retira uma ferramenta ao agente alvo. |
| `remember` | Acrescenta um facto à memória do agente alvo. |

Não é preciso saber os nomes técnicos das flags: o `set_flag` é conduzido pelo próprio
modelo, por isso basta pedir por palavras tuas ("deixa o agente de apoio ao cliente agir
sobre os ficheiros que os clientes lhe enviam", "para de limitar as mensagens deste
agente") que ele escolhe o interruptor certo.

A persona e a memória vivem no workspace do agente alvo. As ferramentas e o modelo ficam
guardados na entrada desse agente no ficheiro de configuração.

## A barreira de permissão

Por ser uma ferramenta de risco, toda e qualquer utilização do `manage_agent` passa pela
barreira de permissão: o agente propõe a alteração, tu aprovas, e só depois disso é que
ela é escrita. Um agente nunca consegue mexer em agentes fora do seu próprio âmbito
`can_manage`, e qualquer pedido nesse sentido é simplesmente recusado.
