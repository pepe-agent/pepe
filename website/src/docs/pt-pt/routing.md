---
title: Encaminhamento entre agentes
description: A ferramenta send_to_agent deixa um agente entregar trabalho a outro, sob uma lista de rotas que tu controlas, sentido a sentido.
---

Os agentes conseguem falar uns com os outros através da ferramenta `send_to_agent`.
Quem pode chamar quem fica definido numa **lista de rotas dirigida**: o campo
`can_message` de cada agente guarda os nomes a quem *esse* agente tem permissão para
escrever. Ter uma rota de `triage` para `billing` não abre automaticamente o sentido
inverso, de `billing` para `triage`.

Quando um agente encaminha uma mensagem, quem recebe responde numa execução própria e
nova, e essa resposta volta para quem chamou como resultado da ferramenta. Existe um
limite de saltos e uma verificação de ciclos, para que uma cadeia de chamadas
encaminhadas nunca fique presa a repetir-se para sempre.

Note-se que o `send_to_agent` não troca quem está de facto a falar com o utilizador:
é só uma consulta pontual, e continua a ser o agente que chamou a responder na
conversa. Passar a conversa **toda** para outro agente, a partir daí em diante, é
trabalho do `switch_agent`, uma ferramenta diferente que vemos mais abaixo.

## Criar uma rota

```bash
# triage passa trabalho a billing; billing pode escalar para refunds
pepe agent route triage billing
pepe agent route triage refunds
pepe agent route billing refunds

# revogar uma rota
pepe agent route triage billing --remove

# ou já definir isto na criação do agente
pepe agent add triage --model mock --can-message billing,refunds
```

As rotas ficam guardadas em `~/.pepe/config.json`, dentro da lista `can_message` de
cada agente:

```jsonc
"agents": {
  "triage":  { "can_message": ["billing", "refunds"] },
  "billing": { "can_message": ["refunds"] },
  "refunds": { "can_message": [] }
}
```

Repara que `refunds` tem um `can_message` vazio: responde quando é chamado, mas não
tem para onde ligar de volta. E como a lista tem sentido único, dar a `billing` uma
rota para `refunds` não abre nada no sentido contrário.

Também não basta constar da lista: o agente precisa de ter `send_to_agent` entre as
suas `tools` para conseguir encaminhar seja o que for. Uma coisa diz a quem ele pode
ligar, a outra é o que lhe permite discar.

<div class="note"><strong>Fronteiras de projeto.</strong> Uma rota nunca atravessa a
fronteira entre projetos. Um nome simples em <code>--can-message</code> resolve-se
sempre dentro do projeto do próprio agente, e a CLI recusa ligar dois agentes que
vivam em projetos diferentes.</div>

## Passar a conversa toda a outro agente, por agora (`switch_agent`)

Se o `send_to_agent` serve para uma consulta pontual, o `switch_agent` resolve outro
problema: o agente que está a responder agora entrega o **resto da conversa** a um
colega, acessível a partir de um pedido comum, do tipo "liga-me ao billing" ou "quero
falar com o suporte diretamente", sem precisar de comando nenhum.

```text
Liga-me diretamente ao agente billing.
```

O agente chama `switch_agent` com `target: "billing"`. A resposta a *este* turno em
concreto ainda sai de quem já estava a falar ("certo, a ligar-te agora"); só a partir
da mensagem seguinte é que a troca entra em vigor. O agente novo arranca com um
contexto limpo, sem herdar nada do histórico desta conversa.

Isto é temporário de propósito: dura só até ao próximo `/new`, que devolve a conversa
ao agente com quem ela realmente começou. **Não é a mesma coisa** que `/agent NOME`
(ou pedir ao agente "vincula este canal ao billing a partir de agora, para sempre") -
isso é uma alteração permanente à configuração do canal, coberta em
[Telegram](../telegram/) e [Webhooks](../webhooks/), e é o tipo que o `/new` não
desfaz. Usa o `switch_agent` para "liga-me ao billing agora"; usa o tipo permanente
para "este canal passa a ser sempre do billing".

A lista usada é exatamente a mesma `can_message` do `send_to_agent`: se um agente já
pode escrever a um colega, também já pode passar-lhe a conversa, sem precisar de
configurar nada a mais para isso. Tal como o `send_to_agent`, o `switch_agent` **não**
passa pela barreira de permissão humana: a rota já é a autorização. Um canal que nunca
deve trocar de agente usa `agent_switch_locked`, que o recusa de vez.

## O encaminhamento e a barreira de permissão

A própria lista de rotas *é* a autorização para a chamada do `send_to_agent`. Já foi
o operador quem decidiu, na configuração, que este agente pode escrever àquele, e por
isso a chamada em si não precisa de passar pela barreira humana: corre sem mais.

É exatamente por essa razão que a lista tem sentido único e começa fechada, em vez de
ser simétrica e aberta. Uma concessão estreita e explícita, um sentido de cada vez, é
o que torna seguro dispensar a barreira nesse caso concreto. Se fosse simétrica,
entregaria em silêncio a quem foi chamado uma rota de volta para quem o chamou, coisa
que ninguém pediu.

As ferramentas de risco do agente chamado são outra história à parte, e continuam
sujeitas a barreira. Quando o `billing` corre `bash` ou `write_file`, essa chamada
passa pela permissão exatamente como passaria se fosses tu a falar com o `billing`
diretamente. O encaminhamento só abre o caminho entre dois agentes; nunca lava as
permissões de quem está do outro lado.

## Alterar rotas pela conversa

Dando a um agente a ferramenta `manage_agent`, ele passa a conseguir acrescentar ou
remover rotas em conversa normal, guiado pela skill nativa `manage-routing`, para
qualquer agente sobre o qual tenha autoridade `can_manage` (por definir, o padrão
é só ele próprio). As ações `allow_route`/`deny_route` recebem `{target, value}`,
onde `target` é quem envia e `value` é quem recebe.

```text
Autoriza-te a ti próprio a enviar mensagens ao agente billing.
```

O agente chama `manage_agent` com `action: "allow_route"`, `target` ele
próprio, e `value: "billing"`. Como isto altera configuração, passa mesmo pela
barreira de permissão: tens de autorizar a rota nova antes de ela ficar
escrita em disco. E o encaminhamento continua com sentido único, por isso
autorizar este caminho não abre nenhum de volta para o `billing` responder
por conta própria.
