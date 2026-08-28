---
title: Grafos
description: Nós e arestas com estado compartilhado que sobrevive entre chamadas de modelo separadas, e um verificador capaz de mandar o fluxo de volta a um passo anterior para uma revisão de verdade.
---

## Por que isso existe

Numa conversa comum há um agente só, um loop só, decidindo o próximo passo chamada a chamada. Isso resolve quase tudo. Só deixa de bastar quando o trabalho ganha uma *estrutura* real: um rascunho que uma segunda revisão precisa poder rejeitar de fato e devolver, não apenas tentar de novo às cegas; um passo que tem que esperar por uma pessoa antes de seguir; várias coisas que vale a pena checar ao mesmo tempo antes de decidir o que vem depois.

Um **grafo** é um fluxo de trabalho nomeado, feito de nós e arestas, com estado que atravessa chamadas de modelo separadas, algo que nenhum outro mecanismo de automação do Pepe oferece. Um [flow](../flows/) reproduz uma sequência exata e já comprovada de chamadas de ferramenta sem chamar o modelo nenhuma vez, feito para um trabalho que você já repetiu vezes o bastante para não precisar mais decidir nada. A [delegação](../delegation/) espalha uma tarefa entre trabalhadores só de leitura, que não compartilham estado entre si e não podem agir. O grafo cobre o meio do caminho: trabalho de fato dividido em vários passos, com ramificações que dependem do que uma revisão real encontrou, ainda chamando o modelo a cada etapa.

## Tipos de nó

Não existe linguagem nova para aprender além de uma única substituição `{{key}}` dentro do texto de um nó. Um grafo tem cinco tipos de nó:

- **agent**: chama um modelo com um prompt já renderizado. A resposta fica disponível para qualquer nó seguinte como `{{id}}`. `next` indica o próximo nó; sem ele, o grafo termina ali.
- **verifier**: faz o mesmo tipo de chamada, mas a resposta precisa terminar numa linha com exatamente uma palavra de um conjunto fixo de vereditos (por exemplo, `{"pass": "publish", "fail": "draft"}`). É essa palavra que decide para onde o fluxo segue, e o destino pode muito bem ser um nó *anterior*: essa é justamente a revisão de verdade para a qual o recurso existe, já que o nó anterior passa a ver a crítica do verificador na próxima vez que rodar, via `{{esse_verifier_id}}`.
- **human**: nenhuma chamada ao modelo. A execução para e espera; assim que a resposta de alguém chegar, ela vira o valor desse nó para tudo que roda depois.
- **parallel**: espalha uma lista de tarefas entre trabalhadores só de leitura, com as mesmas restrições da [delegação](../delegation/): eles podem pesquisar, não agir. A resposta combinada vira o valor do nó.
- **tool**: chama uma ferramenta específica diretamente, passando pela mesma barreira de permissão de qualquer chamada de ferramenta, e só pode ser uma ferramenta que o agente dono do grafo já possui.

### Templates

`{{input}}` é o que foi passado quando o grafo começou a rodar. `{{node_id}}` lê a saída anterior daquele nó e derruba a execução se ele ainda não produziu nenhuma, o que quase sempre é um erro que vale a pena capturar em vez de deixar passar um prompt pela metade. `{{node_id?}}` lê da mesma forma, mas cai num texto reserva em vez de falhar: é exatamente disso que um nó de loop-back precisa, já que na primeira passagem ainda não existe crítica nenhuma para mostrar. `{{node_id|default:"algum texto"}}` usa um literal próprio no lugar do texto reserva padrão.

## Um exemplo

Um rascunho que um revisor pode de fato rejeitar, uma aprovação humana antes de publicar, e um passe final de formatação:

```json
{
  "name": "research-and-verify",
  "agent": "assistant",
  "entry": "draft",
  "nodes": [
    { "id": "draft", "type": "agent",
      "prompt": "Escreva sobre {{input}}. Crítica anterior: {{verify?}}",
      "next": "verify" },
    { "id": "verify", "type": "verifier",
      "prompt": "Revise procurando afirmações sem fonte:\n\n{{draft}}",
      "verdicts": { "pass": "review_human", "fail": "draft" } },
    { "id": "review_human", "type": "human",
      "ask": "Aprova publicar isso?\n\n{{draft}}",
      "next": "publish" },
    { "id": "publish", "type": "agent",
      "prompt": "Formate como saída final:\n\n{{draft}}\n\nDecisão humana: {{review_human}}" }
  ]
}
```

Quando `verify` responde "fail", o fluxo volta para `draft`, que passa a enxergar a crítica através de `{{verify?}}`, em vez de simplesmente tentar de novo no escuro. Quando responde "pass", uma pessoa dá o aval antes mesmo de `publish` rodar.

## Definindo, rodando e inspecionando

Um agente consegue definir e rodar os próprios grafos pela conversa (`manage_graph`, `run_graph`, `inspect_graph_run`), ou você pode fazer isso direto:

```bash
pepe graph import research.json                      # o arquivo já diz o próprio agente
pepe graph list --agent assistant                     # todos os grafos daquele agente
pepe graph run assistant research-and-verify --input "os números do Q3"
pepe graph runs --agent assistant                     # todas as execuções, inclusive as pausadas
pepe graph inspect grun_a1b2c3d4                       # histórico completo de uma execução
```

A importação confere a estrutura inteira de uma vez só: alvos que não existem, um nó sem permissão para nomear determinado agente, uma ferramenta que um nó tenta usar sem que o agente realmente a tenha. E ela reporta todos os problemas encontrados, não apenas o primeiro.

Quando uma execução chega a um nó `human`, ela volta com o status `waiting_human` e traz exatamente o que foi perguntado. Resolva assim que a resposta estiver pronta:

```bash
pepe graph resume grun_a1b2c3d4 "sim, pode publicar"
```

Nada da execução se perde enquanto ela espera. Fica parada exatamente onde parou, pelo tempo que for preciso.

## Rodando numa agenda

```bash
pepe graph schedule assistant research-and-verify --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

É o mesmo mecanismo de um prompt ou flow [agendado](../scheduled/), só que com outro tipo de trabalho por baixo. Um grafo agendado que pausa num nó `human` continua esperando por uma pessoa; o timer disparar a execução não faz ninguém aparecer mais rápido para responder.

<div class="note"><strong>Um verificador que nunca concorda não fica girando para sempre.</strong> Todo grafo tem um orçamento de passos (25 por padrão, com possibilidade de subir até 100), então um loop de revisão que nunca converge falha de forma limpa assim que esse orçamento acaba, em vez de rodar indefinidamente. E a desconfiança não se espalha pela execução inteira: um nó só começa sem confiança quando efetivamente lê algo vindo de conteúdo externo, como uma página buscada ou um documento enviado, e só aquela chamada específica perde as ferramentas pré-aprovadas. Um nó que lê apenas estado limpo roda com confiança total, mesmo numa execução em que outro ramo tenha tocado em algo externo.</div>
