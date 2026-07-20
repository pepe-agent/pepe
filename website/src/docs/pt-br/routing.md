---
title: Roteamento entre agentes
description: Deixe um agente passar trabalho para outro com a ferramenta send_to_agent, sob uma lista de rotas permitidas direcionada que diz exatamente quem pode chamar quem.
---

Os agentes podem se falar através da ferramenta `send_to_agent`. Quem pode chamar quem
é definido por uma **lista de rotas permitidas direcionada**: o campo `can_message` de
cada agente lista os agentes para os quais *ele* pode enviar mensagens. Uma rota de
`triage` para `billing` não implica uma rota de `billing` de volta para `triage`.

Quando um agente roteia uma mensagem, o agente chamado responde em uma execução nova, e
a resposta volta para quem chamou como resultado da ferramenta. Um limite de saltos e
uma verificação de ciclo impedem que as cadeias de chamadas entrem em loop.

O `send_to_agent` nunca muda quem está de fato falando com o usuário: é uma consulta
pontual, e quem chamou continua sendo o agente que responde a conversa. Passar a
conversa **inteira** para outro agente a partir de agora é o `switch_agent`, uma
ferramenta diferente, coberta mais abaixo.

## Criando uma rota

```bash
# triage passa trabalho para billing; billing pode escalar para refunds
pepe agent route triage billing
pepe agent route triage refunds
pepe agent route billing refunds

# revogar uma rota
pepe agent route triage billing --remove

# ou defina tudo já na criação do agente
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

O `refunds` tem um `can_message` vazio, então ele responde quando é chamado, mas não
pode chamar ninguém de volta. Como a lista é direcionada, conceder a rota de `billing`
para `refunds` não concede nada no sentido inverso.

O agente também precisa ter `send_to_agent` na sua lista de `tools` para conseguir
rotear. A lista de rotas permitidas decide quem ele pode chamar, e a ferramenta é o que
lhe permite fazer a chamada.

<div class="note"><strong>Fronteiras de projeto.</strong> As rotas nunca atravessam a
fronteira de um projeto. Nomes simples em <code>--can-message</code> são resolvidos
dentro do próprio projeto do agente, e a CLI recusa uma rota entre dois agentes que
estejam em projetos diferentes.</div>

## Passando a conversa inteira adiante (`switch_agent`)

O `send_to_agent` é uma consulta pontual; o `switch_agent` é a outra coisa: o agente
que está respondendo agora passa o **resto da conversa** para outro agente. É o mesmo
efeito de o usuário digitar `/agent NOME` sozinho, só que acessível por um pedido comum
("me conecta com o billing", "quero falar direto com o suporte") em vez do comando de
barra.

```text
Me conecta direto com o agente billing.
```

O agente chama `switch_agent` com `target: "billing"`. A resposta dele para *este*
turno continua saindo do agente que já está respondendo ("beleza, te conectando
agora"); a troca só entra em vigor a partir da próxima mensagem, o mesmo
comportamento que o `/agent` já tem. O novo agente começa com um contexto limpo; não
herda o histórico desta conversa.

Ele usa exatamente a mesma lista `can_message` do `send_to_agent`: se um agente pode
enviar mensagem a um par, também pode passar a conversa para ele, sem precisar
configurar uma rota separada. Diferente do `send_to_agent`, o `switch_agent`
**passa** pela barreira de permissão normal por padrão: ele muda quem responde toda
mensagem daqui pra frente, uma ação maior que passa despercebida com facilidade se
liberada sem querer.

## Roteamento e a barreira de permissão

A lista de rotas permitidas *é* a autorização da chamada do `send_to_agent`. O operador
já decidiu, na configuração, que este agente pode enviar mensagens àquele agente, então
a própria chamada não passa pela barreira de permissão humana. Ela simplesmente
executa.

É exatamente por isso que a lista é direcionada e fechada por padrão, em vez de
simétrica e aberta. A concessão é estreita e explícita, um sentido de cada vez, e é isso
que torna seguro permitir uma chamada sem barreira. Uma lista simétrica entregaria em
silêncio ao agente chamado uma rota de volta para quem o chamou, sem que ninguém
tivesse pedido.

As ferramentas de risco do agente chamado são outra história, e continuam com barreira.
Quando o `billing` executa `bash` ou `write_file`, essa chamada passa pela barreira de
permissão exatamente como passaria se você tivesse falado com o `billing` diretamente.
O roteamento deixa um agente alcançar outro, mas nunca lava as permissões desse outro
agente.

## Alterando rotas pela conversa

Dê a um agente a ferramenta `set_route` e ele passa a adicionar ou remover rotas pela
conversa, guiado pela skill nativa `manage-routing`. A ferramenta recebe
`{from, to, action}`, e o `from` assume por padrão o próprio agente que chamou.

```text
Libere para você mesmo o envio de mensagens ao agente billing.
```

O agente chama `set_route` com `action: "allow"` e `to: "billing"`. Como isso edita a
configuração, o `set_route` passa sim pela barreira de permissão: você autoriza a nova
rota antes que ela seja gravada em disco. O roteamento continua direcionado, então
liberar esta rota não permite que o `billing` responda por iniciativa própria.
