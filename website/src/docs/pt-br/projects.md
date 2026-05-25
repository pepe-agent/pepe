---
title: Projetos
description: Isole um cliente do outro para que uma única instalação possa atender vários projetos sem que os dados de um jamais cruzem para o outro.
---

## O que é um projeto

Um projeto é um escopo de cliente isolado. Uma única instalação pode atender vários
clientes, e nada cruza de um para o outro: nem arquivos, nem roteamento, nem chaves de
modelo.

Todo tenant é um projeto, inclusive o primeiro. Toda instalação já vem com um **projeto
default** (slug `default`), e é nele que todo comando cai quando você omite `--project`.
O default é um projeto normal como qualquer outro: aparece em `project list`, pode ser
renomeado, e tem billing próprio. Você só cria projetos adicionais quando realmente
precisa isolar clientes uns dos outros; até lá, tudo vive no default e uma instalação de
cliente único nunca precisa pensar em projetos.

<div class="note"><strong>No painel.</strong> A página Projects lista todos os projetos,
inclusive o default. O default não é um caso especial: você o vê na lista, edita o nome
e a margem dele, e mede o billing dele como o de qualquer outro.</div>

## O handle é a identidade

A identidade real de um agente é o seu **handle**. No projeto default, o handle é apenas
o nome simples (`sales`). Dentro de outro projeto, ele é qualificado como `projeto/nome`
(`acme/sales`). O mesmo nome simples pode ser reutilizado em cada projeto, então
`acme/sales` e `globex/sales` são dois agentes diferentes.

O handle é o que indexa tudo: a entrada de configuração, o diretório do workspace, as
sessões e as rotas. Por isso o isolamento não é uma funcionalidade separada, colada por
cima. Ele decorre do handle.

### Arquivos

O workspace de um agente é `~/.pepe/projects/<slug>/agents/<nome>/` e o espaço
compartilhado dele é `~/.pepe/projects/<slug>/shared/`. Agentes com o mesmo nome em
projetos diferentes nunca escrevem no mesmo diretório, e um caminho `shared/...` nunca
vaza entre clientes. Os agentes do projeto default ficam sob o slug `default`, exatamente
como os de qualquer outro projeto.

### Roteamento

`send_to_agent` nunca cruza a fronteira de um projeto. Um destino informado pelo nome
simples resolve para um par dentro do próprio projeto do remetente, e uma trava rígida
recusa qualquer rota entre projetos, mesmo que uma lista de permissões peça por ela.

### Modelos e chaves

Um agente resolve seus modelos primeiro dentro do próprio projeto e, só depois, cai para
o projeto default. Um projeto pode, assim, fixar chaves de provedor privadas que nenhum
outro projeto enxerga, ou herdar um único provedor global compartilhado. O agente ou o
modelo de um projeto nunca é promovido a padrão global, nem quando é o primeiro a ser
criado.

## Criando e usando um projeto

```bash
pepe project add acme --description "Acme Inc"
pepe project add globex
pepe project list

# agentes, modelos e rotas aceitam --project
pepe model add llm  --project acme --base-url ... --api-key '${ACME_KEY}' --model ...
pepe agent add sales   --project acme --prompt "..." --can-message support
pepe agent add support --project acme --prompt "..."
pepe agent route sales support --project acme   # ambos resolvem dentro da acme

pepe agent list --project acme    # só os da Acme
pepe agent list                   # só os do projeto default
pepe agent list --all             # todos os projetos
pepe chat --project acme sales    # ou: pepe run acme/sales "..."
```

## Renomeando e removendo

```bash
pepe project rename acme umbrella   # troca só o rótulo e move o diretório dela;
                                    # rotas, permissões, defaults, crons, watches,
                                    # bots e tokens seguem apontando, por id
pepe project remove acme            # recusa enquanto ela ainda tiver agentes
pepe project remove acme --force    # remove o projeto, e os agentes dele junto
```

Renomear é seguro porque toda referência é por **id**, não por nome. Cada projeto (assim
como cada modelo e cada agente) tem um id interno estável; o slug e o nome são apenas
rótulos mutáveis. Renomear um projeto só troca o rótulo e move o diretório dele, então
nenhuma rota, permissão, padrão ou binding de cron, bot ou token fica pendurado. O projeto
default também pode ser renomeado assim.

## Como fica na configuração

Os projetos são um mapa chaveado por um **id** estável, cada entrada com um `slug` e um
`name` (ambos rótulos editáveis), mais um ponteiro `default_project` no topo, apontando
para o id do projeto default:

```jsonc
"default_project": "p_1a2b3c4d",
"projects": {
  "p_1a2b3c4d": { "slug": "default", "name": "Default" },
  "p_5e6f7a8b": { "slug": "acme", "name": "Acme Inc", "default_model": "llm" }
},
"agents": {
  "assistant":    { "can_message": [] },          // projeto default
  "acme/sales":   { "can_message": ["acme/support"] },
  "acme/support": { "can_message": [] }
}
```

## Projetos e canais

Um bot do Telegram ligado a um agente de um projeto mantém a conversa inteira dentro
daquele projeto. Um bot ligado a um agente do projeto default atende o default,
exatamente como fazia numa instalação de cliente único.

## Tetos de gasto e de mensagens

O projeto também é a unidade que o faturamento mede. Toda chamada de modelo é medida por
projeto, e um projeto pode carregar um teto mensal de gasto, um teto mensal de mensagens
de clientes e uma margem de cobrança. O projeto default tem billing próprio como qualquer
outro. Veja [Cobrança e limites](../billing/) para definir, limpar e resetar esses tetos,
e [Agentes](../agents/) para os campos do agente que o projeto delimita.
