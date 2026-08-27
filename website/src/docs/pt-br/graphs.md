---
title: Grafos
description: Nós, arestas e estado compartilhado que sobrevive a chamadas de modelo separadas, com um verificador que pode mandar o fluxo de volta a um passo anterior para uma revisão de verdade.
---

## Por que isso existe

Uma conversa normal é um agente, um loop, decidindo o que fazer chamada a chamada. Isso cobre quase tudo. Deixa de bastar assim que um trabalho tem uma *estrutura* real: um rascunho que uma segunda revisão deveria poder rejeitar de verdade e devolver, não só tentar de novo às cegas; um passo que precisa esperar uma pessoa antes de continuar; algumas coisas que vale a pena checar ao mesmo tempo antes de decidir o próximo passo.

Um **grafo** é um fluxo de trabalho com nome, feito de nós e arestas, com estado que sobrevive a chamadas de modelo separadas, algo que nenhuma outra automação do Pepe cobre. Um [flow](../flows/) repete uma sequência exata e já comprovada de chamadas de ferramenta sem nenhuma chamada ao modelo: é para um trabalho que você já fez do mesmo jeito vezes suficientes para não precisar mais decidir. A [delegação](../delegation/) distribui uma tarefa entre trabalhadores só de leitura que não compartilham estado entre si e não podem agir. Um grafo é para o trabalho no meio: genuinamente de vários passos, com ramificação que depende do que uma revisão de verdade encontrou, chamando o modelo a cada passo.

## Tipos de nó

Não tem nenhuma linguagem nova para aprender além de uma única substituição `{{key}}` no texto de um nó. Um grafo tem cinco tipos de nó:

- **agent** - chama um modelo com um prompt já renderizado. A resposta fica disponível para qualquer nó seguinte como `{{id}}`. `next` nomeia o próximo nó; sem ele, o grafo termina ali.
- **verifier** - a mesma chamada, mas a resposta precisa terminar numa linha que contenha exatamente uma palavra de um conjunto fixo de veredictos (`{"pass": "publish", "fail": "draft"}`, por exemplo). Essa palavra decide para onde o fluxo vai depois, e o destino pode ser um nó *anterior*, que é a revisão de verdade para a qual isso existe: o nó anterior vê a crítica do verificador na próxima vez que rodar, via `{{esse_verifier_id}}`.
- **human** - nenhuma chamada ao modelo. A execução pausa e espera; a resposta de alguém, quando chegar, vira o valor desse nó para tudo que vem depois.
- **parallel** - distribui uma lista de tarefas entre trabalhadores só de leitura, as mesmas restrições da [delegação](../delegation/): podem pesquisar, não agir. A resposta combinada vira o valor do nó.
- **tool** - chama uma ferramenta específica diretamente, com a mesma barreira de permissão de qualquer chamada de ferramenta, e só uma ferramenta que o próprio agente do grafo já tem.

### Templates

`{{input}}` é o que foi passado quando o grafo começou. `{{node_id}}` lê a resposta anterior daquele nó, e falha a execução se ele ainda não produziu nenhuma - isso quase sempre é um erro que vale a pena pegar em vez de mandar um prompt pela metade. `{{node_id?}}` lê do mesmo jeito mas cai num texto reserva em vez de falhar, que é exatamente o que um nó de loop-back precisa: na primeira vez que roda, ainda não existe nenhuma crítica. `{{node_id|default:"algum texto"}}` cai num literal seu em vez do texto reserva padrão.

## Um exemplo

Um rascunho que um revisor pode rejeitar de verdade, uma aprovação humana antes de publicar, e um passe final de formatação:

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

Se `verify` disser "fail", o fluxo volta para `draft`, que agora vê a crítica via `{{verify?}}`, em vez de simplesmente tentar de novo às cegas. Se disser "pass", uma pessoa dá o aval antes mesmo de `publish` rodar.

## Definindo, rodando e inspecionando

Um agente define e roda seus próprios grafos pela conversa (`manage_graph`, `run_graph`, `inspect_graph_run`), ou você pode fazer isso direto:

```bash
pepe graph import research.json                      # o arquivo já diz o próprio agente
pepe graph list --agent assistant                     # todos os grafos daquele agente
pepe graph run assistant research-and-verify --input "os números do Q3"
pepe graph runs --agent assistant                     # todas as execuções, inclusive as pausadas
pepe graph inspect grun_a1b2c3d4                       # histórico completo de uma execução
```

Importar confere a estrutura inteira de uma vez, alvos desconhecidos, um nó que não tem permissão para nomear um determinado agente, uma ferramenta que um nó tenta usar mas que o agente na verdade não tem, e reporta todos os problemas encontrados, não só o primeiro.

Uma execução que chega num nó `human` volta como `waiting_human`, com exatamente o que foi perguntado. Resolva quando a resposta estiver pronta:

```bash
pepe graph resume grun_a1b2c3d4 "sim, pode publicar"
```

Nada da execução se perde enquanto ela espera: fica parada exatamente onde parou, pelo tempo que precisar.

## Rodando numa agenda

```bash
pepe graph schedule assistant research-and-verify --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

Mesmo mecanismo de um prompt ou flow [agendado](../scheduled/), só que com outro tipo de trabalho por baixo. Um grafo agendado que pausa num nó `human` continua esperando por uma pessoa: um timer disparar a execução não faz ninguém ficar disponível para responder mais cedo.

<div class="note"><strong>Um verificador que nunca concorda não gira para sempre.</strong> Todo grafo tem um orçamento de passos, 25 por padrão, dá para subir até 100, então um loop de revisão que nunca converge falha de forma limpa assim que se esgota, em vez de rodar para sempre. E a confiança não se espalha pela execução inteira: um nó só começa sem confiança se de fato ler algo que veio de conteúdo externo (uma página buscada, um documento enviado), e só aquela chamada perde suas ferramentas pré-aprovadas, um nó que só lê estado limpo roda com total confiança mesmo numa execução onde outro ramo tocou em algo externo.</div>
