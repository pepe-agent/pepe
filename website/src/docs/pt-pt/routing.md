---
title: Encaminhamento entre agentes
description: Deixa um agente passar trabalho a outro com a ferramenta send_to_agent, sob uma lista de rotas permitidas dirigida que diz exatamente quem pode chamar quem.
---

Os agentes podem falar uns com os outros através da ferramenta `send_to_agent`. Quem
pode chamar quem é definido por uma **lista de rotas permitidas dirigida**: o campo
`can_message` de cada agente indica os agentes a quem *ele* pode enviar mensagens. Uma
rota de `triage` para `billing` não implica uma rota de `billing` de volta para
`triage`.

Quando um agente encaminha uma mensagem, o agente chamado responde numa execução nova, e
a resposta chega a quem chamou como resultado da ferramenta. Um limite de saltos e uma
verificação de ciclos impedem que as cadeias de chamadas entrem em ciclo infinito.

## Criar uma rota

```bash
# triage passa trabalho a billing; billing pode escalar para refunds
pepe agent route triage billing
pepe agent route triage refunds
pepe agent route billing refunds

# revogar uma rota
pepe agent route triage billing --remove

# ou definir logo na criação do agente
pepe agent add triage --model mock --can-message billing,refunds
```

As rotas ficam guardadas em `~/.pepe/config.json`, na lista `can_message` de cada
agente:

```jsonc
"agents": {
  "triage":  { "can_message": ["billing", "refunds"] },
  "billing": { "can_message": ["refunds"] },
  "refunds": { "can_message": [] }
}
```

O `refunds` tem um `can_message` vazio, por isso responde quando é chamado, mas não pode
chamar ninguém de volta. Como a lista é dirigida, conceder a rota de `billing` para
`refunds` não concede nada no sentido inverso.

O agente também precisa de ter `send_to_agent` na sua lista de `tools` para conseguir
encaminhar seja o que for. A lista de rotas permitidas decide a quem ele pode ligar, e a
ferramenta é o que lhe permite fazer a chamada.

<div class="note"><strong>Fronteiras de projeto.</strong> As rotas nunca atravessam a
fronteira de um projeto. Os nomes simples em <code>--can-message</code> são resolvidos
dentro do próprio projeto do agente, e a CLI recusa uma rota entre dois agentes que
estejam em projetos diferentes.</div>

## Encaminhamento e a barreira de permissão

A lista de rotas permitidas *é* a autorização da chamada. O operador já decidiu, na
configuração, que este agente pode enviar mensagens àquele agente, por isso a própria
chamada de `send_to_agent` não passa pela barreira de permissão humana. Simplesmente
executa.

É precisamente por isso que a lista é dirigida e fechada por omissão, em vez de simétrica
e aberta. A concessão é estreita e explícita, um sentido de cada vez, e é isso que torna
seguro permitir uma chamada sem barreira. Uma lista simétrica entregaria em silêncio ao
agente chamado uma rota de regresso a quem o chamou, sem que ninguém a tivesse pedido.

As ferramentas de risco do agente chamado são outra questão, e continuam com barreira.
Quando o `billing` executa `bash` ou `write_file`, essa chamada passa pela barreira de
permissão tal como passaria se tivesses falado diretamente com o `billing`. O
encaminhamento deixa um agente alcançar outro, mas nunca branqueia as permissões desse
outro agente.

## Alterar rotas pela conversa

Dá a um agente a ferramenta `set_route` e ele passa a acrescentar ou remover rotas pela
conversa, guiado pela skill nativa `manage-routing`. A ferramenta recebe
`{from, to, action}`, e o `from` assume por omissão o próprio agente que a chamou.

```text
Autoriza-te a ti próprio a enviar mensagens ao agente billing.
```

O agente chama `set_route` com `action: "allow"` e `to: "billing"`. Como isto edita a
configuração, o `set_route` passa mesmo pela barreira de permissão: autorizas a nova rota
antes de ela ser escrita no disco. O encaminhamento continua dirigido, por isso autorizar
esta rota não permite que o `billing` responda por iniciativa própria.
