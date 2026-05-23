---
title: Empresas
description: Isole um cliente do outro para que uma única instalação possa atender várias empresas sem que os dados de uma jamais cruzem para a outra.
---

## O que é uma empresa

Uma empresa é um escopo de cliente isolado. Uma única instalação pode atender vários
clientes, e nada cruza de um para o outro: nem arquivos, nem roteamento, nem chaves de
modelo.

Empresas são totalmente opcionais. Sem nenhuma empresa, tudo vive no escopo **root**,
que se comporta exatamente como uma instalação de cliente único, e root é o escopo que
todo comando usa quando você omite `--company`. A maioria das instalações nunca precisa
de uma empresa. Crie uma só quando você realmente precisar isolar clientes uns dos
outros.

<div class="note"><strong>No painel.</strong> Root aparece como "Principal", e a página
Companies lista cada empresa de verdade que você criou. Root não é uma empresa de
verdade: nunca aparece em <code>company list</code>, e não pode ser renomeado nem
removido.</div>

## O handle é a identidade

A identidade real de um agente é o seu **handle**. No root, o handle é apenas o nome
simples (`sales`). Dentro de uma empresa, ele é qualificado como `empresa/nome`
(`acme/sales`). O mesmo nome simples pode ser reutilizado em cada empresa, então
`acme/sales` e `globex/sales` são dois agentes diferentes.

O handle é o que indexa tudo: a entrada de configuração, o diretório do workspace, as
sessões e as rotas. Por isso o isolamento não é uma funcionalidade separada, colada por
cima. Ele decorre do handle.

### Arquivos

O workspace de um agente de empresa é `~/.pepe/companies/<empresa>/agents/<nome>/` e o
espaço compartilhado dele é `~/.pepe/companies/<empresa>/shared/`. Agentes com o mesmo
nome em empresas diferentes nunca escrevem no mesmo diretório, e um caminho `shared/...`
nunca vaza entre clientes. Agentes do root mantêm o layout simples, `~/.pepe/agents/<nome>/`
e `~/.pepe/shared/`.

### Roteamento

`send_to_agent` nunca cruza a fronteira de uma empresa. Um destino informado pelo nome
simples resolve para um par dentro da própria empresa do remetente, e uma trava rígida
recusa qualquer rota entre empresas, mesmo que uma lista de permissões peça por ela.

### Modelos e chaves

Um agente de empresa resolve seus modelos primeiro dentro da própria empresa e, só
depois, cai para o root. Uma empresa pode, assim, fixar chaves de provedor privadas que
nenhuma outra empresa enxerga, ou herdar um único provedor global compartilhado. O
agente ou o modelo de uma empresa nunca é promovido a padrão global, nem quando é o
primeiro a ser criado.

## Criando e usando uma empresa

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
pepe agent list --all             # todos os escopos
pepe chat --company acme sales    # ou: pepe run acme/sales "..."
```

## Renomeando e removendo

```bash
pepe company rename acme umbrella   # re-indexa os agentes, modelos, rotas,
                                    # crons, watches, bots, tokens e arquivos dela
pepe company remove acme            # recusa enquanto ela ainda tiver agentes
pepe company remove acme --force    # remove a empresa, e os agentes dela junto
```

## Como fica na configuração

```jsonc
"companies": { "acme": { "description": "Acme Inc", "default_model": "llm" } },
"agents": {
  "assistant":    { "can_message": [] },          // escopo root
  "acme/sales":   { "can_message": ["acme/support"] },
  "acme/support": { "can_message": [] }
}
```

## Empresas e canais

Um bot do Telegram ligado a um agente de empresa mantém a conversa inteira dentro
daquela empresa. Um bot ligado a um agente do root atende o root, exatamente como fazia
antes de você ter qualquer empresa.

## Tetos de gasto e de mensagens

A empresa também é a unidade que o faturamento mede. Toda chamada de modelo é medida por
empresa, e uma empresa pode carregar um teto mensal de gasto, um teto mensal de mensagens
de clientes e uma margem de cobrança. Veja [Cobrança e limites](../billing/) para definir,
limpar e resetar esses tetos, e [Agentes](../agents/) para os campos do agente que a
empresa delimita.
