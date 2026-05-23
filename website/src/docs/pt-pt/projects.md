---
title: Empresas
description: Isola um cliente do outro para que uma única instalação possa servir várias empresas sem que os dados de uma cruzem alguma vez para a outra.
---

## O que é uma empresa

Uma empresa é um âmbito de cliente isolado. Uma única instalação pode servir vários
clientes, e nada cruza de um para o outro: nem ficheiros, nem encaminhamento, nem chaves
de modelo.

As empresas são totalmente opcionais. Sem nenhuma empresa, tudo vive no âmbito **root**,
que se comporta exatamente como uma instalação de cliente único, e root é o âmbito que
todos os comandos usam quando omites `--company`. A maioria das instalações nunca precisa
de uma empresa. Cria uma apenas quando tiveres mesmo de isolar clientes uns dos outros.

<div class="note"><strong>No painel.</strong> O root aparece como "Principal", e a página
Companies lista cada empresa a sério que criaste. O root não é uma empresa a sério: nunca
aparece em <code>company list</code>, e não pode ser renomeado nem removido.</div>

## O handle é a identidade

A identidade real de um agente é o seu **handle**. No root, o handle é apenas o nome
simples (`sales`). Dentro de uma empresa, é qualificado como `empresa/nome`
(`acme/sales`). O mesmo nome simples pode ser reutilizado em cada empresa, por isso
`acme/sales` e `globex/sales` são dois agentes diferentes.

O handle é o que indexa tudo: a entrada de configuração, a pasta do workspace, as sessões
e as rotas. Por isso o isolamento não é uma funcionalidade separada, colada por cima.
Decorre do handle.

### Ficheiros

O workspace de um agente de empresa é `~/.pepe/companies/<empresa>/agents/<nome>/` e o
seu espaço partilhado é `~/.pepe/companies/<empresa>/shared/`. Agentes com o mesmo nome em
empresas diferentes nunca escrevem na mesma pasta, e um caminho `shared/...` nunca escapa
para outro cliente. Os agentes do root mantêm o esquema simples, `~/.pepe/agents/<nome>/`
e `~/.pepe/shared/`.

### Encaminhamento

`send_to_agent` nunca atravessa a fronteira de uma empresa. Um destino indicado pelo nome
simples resolve para um par dentro da própria empresa de quem envia, e uma trava rígida
recusa qualquer rota entre empresas, mesmo que uma lista de permissões a peça.

### Modelos e chaves

Um agente de empresa resolve os seus modelos primeiro dentro da própria empresa e só
depois recorre ao root. Uma empresa pode, assim, fixar chaves de fornecedor privadas que
nenhuma outra empresa vê, ou herdar um único fornecedor global partilhado. O agente ou o
modelo de uma empresa nunca é promovido a predefinição global, nem sequer quando é o
primeiro a ser criado.

## Criar e usar uma empresa

```bash
pepe company add acme --description "Acme Inc"
pepe company add globex
pepe company list

# agentes, modelos e rotas aceitam --company
pepe model add llm  --company acme --base-url ... --api-key '${ACME_KEY}' --model ...
pepe agent add sales   --company acme --prompt "..." --can-message support
pepe agent add support --company acme --prompt "..."
pepe agent route sales support --company acme   # ambos resolvem dentro da acme

pepe agent list --company acme    # só os da Acme
pepe agent list                   # só os do root
pepe agent list --all             # todos os âmbitos
pepe chat --company acme sales    # ou: pepe run acme/sales "..."
```

## Renomear e remover

```bash
pepe company rename acme umbrella   # re-indexa os agentes, modelos, rotas,
                                    # crons, watches, bots, tokens e ficheiros dela
pepe company remove acme            # recusa enquanto ainda tiver agentes
pepe company remove acme --force    # remove-a, e leva os agentes dela também
```

## Como fica na configuração

```jsonc
"companies": { "acme": { "description": "Acme Inc", "default_model": "llm" } },
"agents": {
  "assistant":    { "can_message": [] },          // âmbito root
  "acme/sales":   { "can_message": ["acme/support"] },
  "acme/support": { "can_message": [] }
}
```

## Empresas e canais

Um bot do Telegram ligado a um agente de empresa mantém a conversa inteira dentro dessa
empresa. Um bot ligado a um agente do root serve o root, tal como servia antes de teres
qualquer empresa.

## Limites de despesa e de mensagens

A empresa é também a unidade que a faturação mede. Cada chamada ao modelo é medida por
empresa, e uma empresa pode ter um limite mensal de despesa, um limite mensal de mensagens
de clientes e uma margem de faturação. Vê [Faturação e limites](../billing/) para definir,
limpar e repor esses limites, e [Agentes](../agents/) para os campos do agente que a empresa
delimita.
