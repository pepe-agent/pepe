---
title: Grafos
description: Nós, arestas e estado partilhado que sobrevive a chamadas de modelo separadas, com um verificador que pode devolver o fluxo a um passo anterior para uma revisão a sério.
---

## Porque é que isto existe

Uma conversa normal é um agente, um ciclo, a decidir o que fazer chamada a chamada. Isso cobre quase tudo. Deixa de chegar assim que um trabalho tem uma *estrutura* real: um rascunho que uma segunda passagem devia poder rejeitar a sério e devolver, não só tentar de novo às cegas; um passo que tem de esperar por uma pessoa antes de continuar; algumas coisas que vale a pena verificar ao mesmo tempo antes de decidir o que se segue.

Um **grafo** é um fluxo de trabalho com nome, feito de nós e arestas, com estado que sobrevive a chamadas de modelo separadas, algo que nenhuma outra automação do Pepe cobre. Um [flow](../flows/) repete uma sequência exata e já comprovada de chamadas a ferramentas sem nenhuma chamada ao modelo: é para um trabalho que já fizeste da mesma forma vezes suficientes para já não ser preciso decidir. A [delegação](../delegation/) reparte uma tarefa por trabalhadores só de leitura que não partilham estado entre si e não podem agir. Um grafo é para o trabalho intermédio: genuinamente de vários passos, com ramificação que depende do que uma revisão a sério encontrou, a chamar o modelo em cada passo.

## Tipos de nó

Não há nenhuma linguagem nova a aprender além de uma única substituição `{{key}}` no texto de um nó. Um grafo tem cinco tipos de nó:

- **agent** - chama um modelo com um prompt já renderizado. A resposta fica disponível para qualquer nó seguinte como `{{id}}`. `next` nomeia o próximo nó; sem ele, o grafo termina ali.
- **verifier** - a mesma chamada, mas a resposta tem de terminar numa linha que contenha exatamente uma palavra de um conjunto fixo de veredictos (`{"pass": "publish", "fail": "draft"}`, por exemplo). Essa palavra decide para onde o fluxo vai a seguir, e o destino pode ser um nó *anterior*, que é a revisão a sério para a qual isto existe: o nó anterior vê a crítica do verificador da próxima vez que correr, via `{{esse_verifier_id}}`.
- **human** - nenhuma chamada ao modelo. A execução pausa e espera; a resposta de alguém, quando chegar, passa a ser o valor desse nó para tudo o que vem a seguir.
- **parallel** - reparte uma lista de tarefas por trabalhadores só de leitura, as mesmas restrições da [delegação](../delegation/): podem procurar informação, não agir. A resposta combinada passa a ser o valor do nó.
- **tool** - chama uma ferramenta específica diretamente, com a mesma barreira de permissão de qualquer chamada a ferramenta, e só uma ferramenta que o próprio agente do grafo já tem.

### Templates

`{{input}}` é o que foi passado quando o grafo começou. `{{node_id}}` lê a resposta anterior desse nó, e falha a execução se ele ainda não produziu nenhuma - isso é quase sempre um erro que vale a pena apanhar em vez de enviar um prompt a meio. `{{node_id?}}` lê da mesma forma mas cai num texto de reserva em vez de falhar, que é exatamente o que um nó de retorno precisa: da primeira vez que corre, ainda não existe nenhuma crítica. `{{node_id|default:"algum texto"}}` cai num literal teu em vez do texto de reserva incorporado.

## Um exemplo

Um rascunho que um revisor pode rejeitar a sério, uma aprovação humana antes de publicar, e uma última passagem de formatação:

```json
{
  "name": "research-and-verify",
  "agent": "assistant",
  "entry": "draft",
  "nodes": [
    { "id": "draft", "type": "agent",
      "prompt": "Escreve sobre {{input}}. Crítica anterior: {{verify?}}",
      "next": "verify" },
    { "id": "verify", "type": "verifier",
      "prompt": "Revê à procura de afirmações sem fonte:\n\n{{draft}}",
      "verdicts": { "pass": "review_human", "fail": "draft" } },
    { "id": "review_human", "type": "human",
      "ask": "Aprovas publicar isto?\n\n{{draft}}",
      "next": "publish" },
    { "id": "publish", "type": "agent",
      "prompt": "Formata como resultado final:\n\n{{draft}}\n\nDecisão humana: {{review_human}}" }
  ]
}
```

Se `verify` disser "fail", o fluxo volta para `draft`, que agora vê a crítica através de `{{verify?}}`, em vez de simplesmente voltar a tentar às cegas. Se disser "pass", uma pessoa dá o aval antes sequer de `publish` correr.

## Definir, correr e inspecionar

Um agente define e corre os seus próprios grafos pela conversa (`manage_graph`, `run_graph`, `inspect_graph_run`), ou podes fazê-lo diretamente:

```bash
pepe graph import research.json                      # o ficheiro indica o próprio agente
pepe graph list --agent assistant                     # todos os grafos desse agente
pepe graph run assistant research-and-verify --input "os números do Q3"
pepe graph runs --agent assistant                     # todas as execuções, incluindo as pausadas
pepe graph inspect grun_a1b2c3d4                       # histórico completo de uma execução
```

Importar confirma toda a estrutura de uma vez, destinos desconhecidos, um nó que não tem permissão para nomear um determinado agente, uma ferramenta a que um nó tenta chegar mas que o agente não tem de facto, e reporta todos os problemas encontrados, não só o primeiro.

Uma execução que chega a um nó `human` volta como `waiting_human`, com exatamente o que foi perguntado. Resolve-a quando a resposta estiver pronta:

```bash
pepe graph resume grun_a1b2c3d4 "sim, publica"
```

Nada da execução se perde enquanto espera: fica parada exatamente onde parou, o tempo que for preciso.

## Correr numa agenda

```bash
pepe graph schedule assistant research-and-verify --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

O mesmo mecanismo de um prompt ou flow [agendado](../scheduled/), só que com outro tipo de trabalho por baixo. Um grafo agendado que pausa num nó `human` continua à espera de uma pessoa: um temporizador disparar a execução não faz com que haja alguém disponível para responder mais cedo.

<div class="note"><strong>Um verificador que nunca concorda não pode girar para sempre.</strong> Todo o grafo tem um orçamento de passos, 25 por omissão, e dá para subir até 100, por isso um ciclo de revisão que nunca converge falha de forma limpa assim que se esgota, em vez de correr para sempre. E a confiança não se espalha por toda a execução: um nó só começa sem confiança se de facto ler algo que veio de conteúdo externo (uma página descarregada, um documento carregado), e só essa chamada perde as suas ferramentas pré-aprovadas, um nó que só lê estado limpo corre com total confiança mesmo numa execução em que outro ramo tocou em algo externo.</div>
