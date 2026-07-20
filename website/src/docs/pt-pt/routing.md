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

O `send_to_agent` nunca muda quem está de facto a falar com o utilizador: é uma
consulta pontual, e quem chamou continua a ser o agente que responde à conversa. Passar
a conversa **inteira** a outro agente a partir de agora é o `switch_agent`, uma
ferramenta diferente, abordada mais abaixo.

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

## Passar a conversa inteira a outro agente (`switch_agent`)

O `send_to_agent` é uma consulta pontual; o `switch_agent` é outra coisa: o agente que
está a responder agora passa o **resto da conversa** a outro agente. É o mesmo efeito
de o utilizador digitar `/agent NOME` por si próprio, só que acessível por um pedido
comum ("liga-me ao billing", "quero falar diretamente com o suporte") em vez do
comando de barra.

```text
Liga-me diretamente ao agente billing.
```

O agente chama `switch_agent` com `target: "billing"`. A resposta dele a *este* turno
continua a sair do agente que já está a responder ("certo, a ligar-te agora"); a
troca só entra em vigor a partir da mensagem seguinte, o mesmo comportamento que o
`/agent` já tem. O novo agente começa com um contexto limpo; não herda o histórico
desta conversa.

Usa exatamente a mesma lista `can_message` do `send_to_agent`: se um agente pode
enviar mensagens a um par, também pode passar-lhe a conversa, sem precisar de
configurar uma rota separada. Ao contrário do `send_to_agent`, o `switch_agent`
**passa** pela barreira de permissão normal por omissão: muda quem responde a cada
mensagem a partir daqui, uma ação maior que passa despercebida com facilidade.

## Encaminhamento e a barreira de permissão

A lista de rotas permitidas *é* a autorização da chamada do `send_to_agent`. O operador
já decidiu, na configuração, que este agente pode enviar mensagens àquele agente, por
isso a própria chamada não passa pela barreira de permissão humana. Simplesmente
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
