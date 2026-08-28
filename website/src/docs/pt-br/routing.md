---
title: Roteamento entre agentes
description: Um agente passa trabalho para outro através da ferramenta send_to_agent, e você decide exatamente quem pode chamar quem, sentido por sentido.
---

Agentes conversam entre si pela ferramenta `send_to_agent`. Quem pode chamar quem é
definido por uma **lista de rotas direcionada**: o campo `can_message` de cada agente
traz os agentes para os quais *ele próprio* tem permissão de mandar mensagem. Existir
uma rota de `triage` para `billing` não quer dizer que exista o caminho de volta, de
`billing` para `triage`.

Ao rotear uma mensagem, o agente chamado responde numa execução nova, e essa resposta
volta para quem chamou como resultado da ferramenta. Um limite de saltos junto com uma
checagem de ciclos evita que essas cadeias de chamada entrem em loop infinito.

Importante: `send_to_agent` não transfere a conversa com o usuário para ninguém. É uma
consulta pontual, e o agente que chamou continua sendo quem responde. Para passar a
conversa **inteira** adiante a partir dali existe outra ferramenta, `switch_agent`,
explicada mais abaixo.

## Criando uma rota

```bash
# triage passa trabalho para billing; billing pode escalar para refunds
pepe agent route triage billing
pepe agent route triage refunds
pepe agent route billing refunds

# revogar uma rota
pepe agent route triage billing --remove

# ou já definir tudo na criação do agente
pepe agent add triage --model mock --can-message billing,refunds
```

As rotas vivem em `~/.pepe/config.json`, dentro do `can_message` de cada agente:

```jsonc
"agents": {
  "triage":  { "can_message": ["billing", "refunds"] },
  "billing": { "can_message": ["refunds"] },
  "refunds": { "can_message": [] }
}
```

Repare que `refunds` tem um `can_message` vazio: ele atende quando é chamado, mas não
tem para quem ligar de volta. E como a lista é direcionada, dar a `billing` acesso a
`refunds` não abre nada no caminho contrário.

Só ter a rota configurada não basta: o agente também precisa da `send_to_agent` na
própria lista de `tools`. A lista de rotas decide quem ele pode chamar; a ferramenta é
o que efetivamente permite fazer a ligação.

<div class="note"><strong>Projetos são fronteira.</strong> Uma rota nunca cruza de um
projeto para outro. Um nome simples passado em <code>--can-message</code> é resolvido
dentro do projeto do próprio agente, e a CLI recusa de cara qualquer rota entre agentes
de projetos diferentes.</div>

## Passando a conversa toda adiante: `switch_agent`

Se `send_to_agent` serve para uma consulta pontual, `switch_agent` faz o oposto: o
agente que está respondendo agora entrega o **resto da conversa** para outro agente. O
efeito é idêntico ao de o próprio usuário digitar `/agent NOME`, só que dá pra chegar
lá com um pedido natural ("me conecta com o billing", "quero falar direto com o
suporte"), sem precisar do comando de barra.

```text
Me conecta direto com o agente billing.
```

O agente responde chamando `switch_agent` com `target: "billing"`. A resposta a *este*
turno ainda sai de quem já estava respondendo ("beleza, já te conectando"); a troca só
vale a partir da próxima mensagem, exatamente como já acontece com `/agent`. Do outro
lado, o novo agente começa do zero, sem herdar nada do histórico anterior.

A permissão usada aqui é a mesma lista `can_message` do `send_to_agent`: se um agente
já pode mandar mensagem para outro, também pode entregar a conversa a ele, sem
configuração extra. A diferença é que `switch_agent`, por padrão, **passa** pela
barreira de permissão normal: mudar quem responde a partir dali é uma decisão grande
demais para deixar passar batido sem ninguém perceber.

## Roteamento e a barreira de permissão

A própria lista de rotas já funciona como a autorização para a chamada de
`send_to_agent`. O operador decidiu isso na configuração, então a chamada não para
mais na barreira humana: ela simplesmente acontece.

É exatamente por isso que a lista é direcionada e fechada por padrão, em vez de
simétrica e aberta. Uma concessão estreita, explícita e de mão única é o que torna
seguro deixar essa chamada passar sem barreira. Se a lista fosse simétrica, dar a
`billing` acesso a `refunds` devolveria, de brinde, uma rota de volta que ninguém
pediu.

O que o agente chamado faz com suas próprias ferramentas arriscadas é outra questão, e
aí a barreira continua de pé. Quando `billing` roda `bash` ou `write_file`, isso passa
pela permissão exatamente como passaria se você estivesse falando com `billing` cara a
cara. O roteamento só abre caminho entre agentes; ele nunca lava as permissões de quem
está do outro lado.

## Mudando rotas direto na conversa

Dê a `set_route` a um agente e ele passa a poder adicionar ou remover rotas
conversando, guiado pela skill nativa `manage-routing`. A ferramenta recebe
`{from, to, action}`, e `from` assume por padrão o próprio agente que fez a chamada.

```text
Libere para você mesmo o envio de mensagens ao agente billing.
```

O agente chama `set_route` com `action: "allow"` e `to: "billing"`. Como isso mexe na
configuração, `set_route` passa sim pela barreira de permissão: você autoriza a nova
rota antes que ela seja gravada em disco. E o roteamento segue direcionado, então essa
liberação não dá a `billing` o caminho de volta.
