---
title: Projetos
description: Isola um cliente do outro para que uma única instalação sirva vários clientes sem que os dados de nenhum deles se cruzem alguma vez.
---

## O que é um projeto

Um projeto é uma parede entre clientes. Uma única instalação do Pepe pode servir vários clientes ao mesmo tempo, sem que nada passe de um para o outro: nem ficheiros, nem encaminhamento, nem chaves de modelo.

Todo o cliente (tenant) é um projeto, incluindo aquele que já vem pronto de fábrica. Uma instalação nova traz sempre um único **projeto default** (slug `default`), e é para ele que qualquer comando recorre sempre que omites `--project`. Se serves só a ti próprio, nada disto muda em nada: um nome de agente simples vai sempre parar ao projeto default, por isso nem chegas a pensar em projetos até precisares mesmo de um segundo. Só vale a pena criar um novo quando tens mesmo de manter clientes isolados uns dos outros.

<div class="note"><strong>O projeto default é um projeto como outro qualquer.</strong> Aparece em <code>project list</code> tal como qualquer outro, pode ser renomeado e tem a sua própria faturação. Não existe nenhum âmbito especial de "raiz" com regras diferentes: omitir <code>--project</code> só faz cair de volta no projeto default.</div>

## O handle é a identidade

A identidade real de um agente é o seu **handle**. No projeto default, o handle é só o nome simples (`sales`); dentro de outro projeto, vem qualificado como `projeto/nome` (`acme/sales`). O mesmo nome simples pode repetir-se em cada projeto, por isso `acme/sales` e `globex/sales` acabam por ser dois agentes bem distintos.

É o handle que serve de morada para tudo: encaminhamento, sessões e ligações de canal usam-no todos. Por baixo disso, cada projeto e cada agente carrega ainda um id interno estável, e é esse id, e não o nome (que pode mudar), que fica registado por trás do encaminhamento, das permissões, das predefinições e das ligações a crons, bots e tokens. Renomear um projeto ou um agente troca só o rótulo e move a pasta correspondente; toda a referência acompanha a mudança, por isso nada fica pendurado.

### Ficheiros

O workspace de um agente fica em `~/.pepe/projects/<slug>/agents/<nome>/`, e o espaço partilhado do seu projeto em `~/.pepe/projects/<slug>/shared/`. Dois agentes com o mesmo nome em projetos diferentes nunca escrevem na mesma pasta, e um caminho `shared/...` jamais escapa de um cliente para outro. O projeto default segue exatamente o mesmo esquema, só que sob o seu próprio slug (`~/.pepe/projects/default/…`).

### Encaminhamento

O `send_to_agent` nunca atravessa a fronteira de um projeto. Um destino indicado só pelo nome resolve sempre para um par dentro do próprio projeto de quem envia, e uma trava rígida recusa qualquer rota entre projetos, mesmo que uma lista de permissões chegue a pedi-la.

### Modelos e chaves

Um agente procura primeiro os seus modelos dentro do próprio projeto, e só depois recorre ao projeto default. Isto permite a um projeto fixar chaves de fornecedor privadas que nenhum outro projeto chega a ver, ou então herdar um único fornecedor global partilhado por todos. O agente ou o modelo de um projeto nunca é promovido a predefinição global, nem sequer quando é o primeiro a ser criado.

## Criar e usar um projeto

```bash
pepe project add acme --description "Acme Inc"
pepe project add globex
pepe project list

# agentes, modelos e rotas aceitam todos --project
pepe model add llm  --project acme --base-url ... --api-key '${ACME_KEY}' --model ...
pepe agent add sales   --project acme --prompt "..." --can-message support
pepe agent add support --project acme --prompt "..."
pepe agent route sales support --project acme   # ambos resolvem dentro da acme

pepe agent list --project acme    # só os da Acme
pepe agent list                   # só os do projeto default
pepe agent list --all             # de todos os projetos
pepe chat --project acme sales    # ou: pepe run acme/sales "..."
```

## Renomear e remover

```bash
pepe project rename acme umbrella   # troca o rótulo e move a pasta; tudo o que
                                    # depende do id continua a funcionar sem sobressaltos
pepe project remove acme            # recusa enquanto ainda tiver agentes
pepe project remove acme --force    # remove-o, levando também os seus agentes
```

Como toda a referência é feita por id, renomear um projeto (ou um agente) nunca quebra uma rota, um token, um cron ou uma ligação de bot. O nome é só um rótulo; é o id que tudo aponta de facto.

## Como isto fica na configuração

Os projetos vivem num mapa `"projects"`, indexado por um id estável, cada entrada trazendo o seu `slug` e o seu `name`; e um campo `"default_project"`, ao nível de topo, guarda o id para onde cai qualquer referência simples e sem qualificação.

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

Um bot do Telegram ligado a um agente de um projeto mantém toda a sua conversa dentro desse mesmo projeto. Já um bot ligado a um agente do projeto default continua a servir o projeto default, exatamente como fazia antes de teres criado qualquer outro projeto.

## Limites de despesa e de mensagens

O projeto é também a unidade que a faturação usa para medir tudo. Cada chamada a um modelo é contabilizada por projeto, e um projeto (incluindo o default) pode ter um limite mensal de despesa, um limite mensal de mensagens de clientes e uma margem de faturação própria. Para saberes como definir, limpar e repor esses limites, vê [Faturação e limites](../billing/); para os campos de agente que um projeto delimita, vê [Agentes](../agents/).
