---
title: Projetos
description: Isola um cliente do outro para que uma única instalação possa servir vários projetos sem que os dados de um cruzem alguma vez para o outro.
---

## O que é um projeto

Um projeto é um âmbito de cliente isolado. Uma única instalação pode servir vários
clientes, e nada cruza de um para o outro: nem ficheiros, nem encaminhamento, nem chaves
de modelo.

Todo o tenant é um projeto, incluindo o projeto **default** (slug `default`), aquele para
o qual cada comando recorre quando omites `--project`. O default é um projeto normal como
qualquer outro: aparece na lista, pode ser renomeado e comporta-se exatamente como uma
instalação de cliente único. Uma instalação single-tenant nunca precisa de criar mais
nenhum projeto: escreve nomes de agente simples e tudo resolve para o default. Cria projetos
adicionais apenas quando tiveres mesmo de isolar clientes uns dos outros.

<div class="note"><strong>No painel.</strong> A página Projetos lista todos os projetos,
incluindo o default. O default é um projeto normal para o qual cada comando recorre por
omissão.</div>

## O handle é a identidade

A identidade real de um agente é o seu **handle**. No projeto default, o handle é apenas o
nome simples (`sales`). Dentro de outro projeto, é qualificado como `projeto/nome`
(`acme/sales`). O mesmo nome simples pode ser reutilizado em cada projeto, por isso
`acme/sales` e `globex/sales` são dois agentes diferentes.

O handle é o que indexa tudo: a entrada de configuração, a pasta do workspace, as sessões
e as rotas. Por isso o isolamento não é uma funcionalidade separada, colada por cima.
Decorre do handle.

### Ids estáveis e rename seguro

Por baixo do handle, cada agente tem um **id interno estável**, e cada projeto é guardado
por um **id estável** ao lado do seu `slug` e `name`. O nome (e o slug) é apenas um rótulo
mutável. Renomear um projeto ou um agente troca somente esse rótulo e move o diretório
correspondente: toda a referência interna aponta para o id, por isso nada fica pendurado
quando o nome muda. Rotas, tokens, crons, watches e workspaces continuam ligados através da
renomeação.

### Ficheiros

O workspace de um agente é `~/.pepe/projects/<slug>/agents/<nome>/` e o seu espaço
partilhado é `~/.pepe/projects/<slug>/shared/`. Agentes com o mesmo nome em projetos
diferentes nunca escrevem na mesma pasta, e um caminho `shared/...` nunca escapa para outro
cliente. O projeto default segue o mesmo esquema, com o slug `default`.

### Encaminhamento

`send_to_agent` nunca atravessa a fronteira de um projeto. Um destino indicado pelo nome
simples resolve para um par dentro do próprio projeto de quem envia, e uma trava rígida
recusa qualquer rota entre projetos, mesmo que uma lista de permissões a peça.

### Modelos e chaves

Um agente resolve os seus modelos primeiro dentro do próprio projeto e só depois recorre ao
projeto default. Um projeto pode, assim, fixar chaves de fornecedor privadas que nenhum
outro projeto vê, ou herdar um único fornecedor global partilhado. O agente ou o modelo de
um projeto nunca é promovido a predefinição global, nem sequer quando é o primeiro a ser
criado.

## Criar e usar um projeto

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
pepe agent list --all             # todos os âmbitos
pepe chat --project acme sales    # ou: pepe run acme/sales "..."
```

## Renomear e remover

```bash
pepe project rename acme umbrella   # troca o rótulo e move o diretório; as
                                    # referências por id (agentes, modelos, rotas,
                                    # crons, watches, bots, tokens) seguem intactas
pepe project remove acme            # recusa enquanto ainda tiver agentes
pepe project remove acme --force    # remove-o, e leva os agentes dele também
```

## Como fica na configuração

Os projetos são guardados por **id** estável, cada um com o seu `slug` e `name`, e um
ponteiro `default_project` marca qual é o default:

```jsonc
"default_project": "p_1a2b3c4d",
"projects": {
  "p_1a2b3c4d": { "slug": "default", "name": "Principal" },
  "p_5e6f7a8b": { "slug": "acme", "name": "Acme Inc", "default_model": "llm" }
},
"agents": {
  "assistant":    { "can_message": [] },          // projeto default
  "acme/sales":   { "can_message": ["acme/support"] },
  "acme/support": { "can_message": [] }
}
```

## Projetos e canais

Um bot do Telegram ligado a um agente de um projeto mantém a conversa inteira dentro desse
projeto. Um bot ligado a um agente do projeto default serve o default, tal como servia antes
de teres qualquer outro projeto.

## Limites de despesa e de mensagens

O projeto é também a unidade que a faturação mede. Cada chamada ao modelo é medida por
projeto, e um projeto pode ter um limite mensal de despesa, um limite mensal de mensagens
de clientes e uma margem de faturação. Vê [Faturação e limites](../billing/) para definir,
limpar e repor esses limites, e [Agentes](../agents/) para os campos do agente que o projeto
delimita.
