---
title: Projetos
description: Isole um cliente do outro para que uma única instalação possa atender vários projetos sem que os dados de um jamais cruzem para o outro.
---

## O que é um projeto

Um projeto é um escopo de cliente isolado. Uma única instalação pode atender vários clientes, e nada cruza de um para o outro: nem arquivos, nem roteamento, nem chaves de modelo.

Todo tenant é um projeto, inclusive o primeiro. Toda instalação já vem com um **projeto default** (slug `default`), e é nele que todo comando cai quando você omite `--project`. Se você atende só a si mesmo, nada muda: um nome de agente simples vai para o projeto default, então você nunca precisa pensar em projetos até o dia em que quiser um segundo. Só crie um novo quando realmente precisar isolar clientes uns dos outros.

<div class="note"><strong>O projeto default é um projeto normal.</strong> Ele aparece em <code>project list</code> como qualquer outro, pode ser renomeado, e tem billing próprio. Não existe um escopo especial de "raiz" com regras diferentes; omitir <code>--project</code> só faz cair de volta no projeto default.</div>

## O handle é a identidade

A identidade real de um agente é o seu **handle**. No projeto default, o handle é apenas o nome simples (`sales`). Dentro de outro projeto, ele é qualificado como `projeto/nome` (`acme/sales`). O mesmo nome simples pode ser reutilizado em cada projeto, então `acme/sales` e `globex/sales` são dois agentes diferentes.

É o handle que endereça tudo: roteamento, sessões e vínculos de canal usam ele. Por baixo dos panos, todo projeto e todo agente também carrega um id interno estável, e é esse id, não o nome (que pode mudar), que fica registrado em roteamento, permissões, padrões e vínculos de cron, bot e token. Renomear um projeto ou um agente só troca o rótulo e move o diretório dele; toda referência acompanha, então nada fica pendurado.

### Arquivos

O workspace de um agente é `~/.pepe/projects/<slug>/agents/<nome>/`, e o espaço compartilhado do projeto dele é `~/.pepe/projects/<slug>/shared/`. Agentes com o mesmo nome em projetos diferentes nunca escrevem no mesmo diretório, e um caminho `shared/...` nunca vaza entre clientes. O projeto default segue essa mesma organização sob o próprio slug (`~/.pepe/projects/default/…`).

### Roteamento

`send_to_agent` nunca cruza a fronteira de um projeto. Um destino informado pelo nome simples resolve para um par dentro do próprio projeto do remetente, e uma trava rígida recusa qualquer rota entre projetos, mesmo que uma lista de permissões peça por ela.

### Modelos e chaves

Um agente resolve seus modelos primeiro dentro do próprio projeto e, só depois, cai para o projeto default. Um projeto pode, assim, fixar chaves de provedor privadas que nenhum outro projeto enxerga, ou herdar um único provedor global compartilhado. O agente ou o modelo de um projeto nunca é promovido a padrão global, nem quando é o primeiro a ser criado.

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
                                    # todo vínculo continua apontando certo, por id
pepe project remove acme            # recusa enquanto ela ainda tiver agentes
pepe project remove acme --force    # remove o projeto, e os agentes dele junto
```

Como toda referência é por id, renomear um projeto (ou um agente) nunca quebra uma rota, um token, um cron ou um vínculo de bot. O nome é só um rótulo; o id é o que tudo realmente aponta.

## Como fica na configuração

Os projetos vivem num mapa `"projects"` chaveado por um id estável, cada entrada carregando um `slug` e um `name`, e um `"default_project"` no nível raiz nomeia o id para onde toda referência simples e não qualificada cai de volta.

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

Um bot do Telegram vinculado a um agente de um projeto mantém a conversa inteira dentro daquele projeto. Um bot vinculado a um agente do projeto default atende o projeto default, exatamente como fazia antes de você criar qualquer segundo projeto.

## Tetos de gasto e de mensagens

O projeto também é a unidade que o faturamento mede. Toda chamada de modelo é medida por projeto, e um projeto pode carregar um teto mensal de gasto, um teto mensal de mensagens de clientes e uma margem de cobrança, o projeto default incluído. Veja [Cobrança e limites](../billing/) para definir, limpar e resetar esses tetos, e [Agentes](../agents/) para os campos do agente que o projeto delimita.
