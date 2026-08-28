---
title: Grafos
description: Nós, arestas e estado partilhado que sobrevive entre chamadas de modelo distintas, com um verificador capaz de devolver o fluxo a um passo anterior para uma revisão a sério.
---

## Porque é que isto existe

Uma conversa normal é um agente, um ciclo, a decidir o que fazer chamada a
chamada, e isso já cobre quase tudo. Deixa de chegar no momento em que um
trabalho passa a ter **estrutura** a sério: um rascunho que uma segunda
passagem devia poder rejeitar de facto e devolver, em vez de tentar outra
vez às cegas; um passo que precisa de esperar por uma pessoa antes de
continuar; várias coisas que valem a pena confirmar ao mesmo tempo antes de
decidir o próximo passo.

Um **grafo** é um fluxo de trabalho com nome, composto por nós e arestas,
com estado que sobrevive entre chamadas de modelo distintas, algo que
nenhuma outra automação do Pepe oferece. Um [flow](../flows/) reproduz uma
sequência exata e já comprovada de chamadas a ferramentas, sem qualquer
chamada ao modelo: serve para um trabalho já repetido vezes suficientes
para deixar de precisar de decisão. A [delegação](../delegation/) reparte
uma tarefa por trabalhadores só de leitura, que não partilham estado entre
si e não conseguem agir. O grafo fica algures no meio: trabalho genuinamente
feito de vários passos, com ramificações que dependem do que uma revisão a
sério encontrou, chamando o modelo em cada um deles.

## Tipos de nó

Não há linguagem nova nenhuma para aprender, além de uma única substituição
`{{chave}}` dentro do texto de um nó. Um grafo conhece cinco tipos:

- **agent**: chama um modelo com um prompt já preenchido. A resposta fica
  disponível para qualquer nó posterior através de `{{id}}`. O campo `next`
  indica o nó seguinte; deixa-o de fora e o grafo termina ali mesmo.
- **verifier**: faz o mesmo tipo de chamada, mas a resposta tem
  obrigatoriamente de terminar numa linha com exatamente uma palavra de um
  conjunto fixo de veredictos (por exemplo, `{"pass": "publish", "fail":
  "draft"}`). É essa palavra que decide para onde o fluxo segue a seguir, e
  o destino pode muito bem ser um nó *anterior*, que é exatamente a revisão
  a sério para a qual isto tudo existe: da próxima vez que correr, esse nó
  anterior vê a crítica do verificador através de `{{id_do_verificador}}`.
- **human**: não faz chamada nenhuma ao modelo. A execução pausa e espera;
  assim que alguém responde, essa resposta passa a ser o valor do nó para
  tudo o que vem depois.
- **parallel**: reparte uma lista de tarefas por trabalhadores só de
  leitura, com as mesmas restrições da [delegação](../delegation/): podem
  procurar informação, não podem agir. O valor do nó é a resposta
  combinada de todos.
- **tool**: chama diretamente uma ferramenta específica, sujeita à mesma
  barreira de permissão de qualquer outra chamada a ferramenta, e só pode
  ser uma que o próprio agente do grafo já tenha.

### Templates

`{{input}}` corresponde a tudo o que foi passado no arranque do grafo.
`{{id_do_no}}` lê a saída anterior desse nó, e faz falhar a execução se ele
ainda não tiver produzido nenhuma, o que quase sempre é um erro que vale a
pena apanhar em vez de disparar um prompt pela metade. `{{id_do_no?}}` lê da
mesma forma, mas em vez de falhar recorre a um texto de reserva, exatamente
o que um nó de retorno precisa: à primeira vez que corre, ainda não existe
crítica nenhuma para mostrar. Já `{{id_do_no|default:"algum texto"}}`
recorre a um literal escolhido por ti, em vez do texto de reserva
incorporado.

## Um exemplo

Um rascunho que um revisor consegue mesmo rejeitar, seguido de uma
aprovação humana antes de publicar, e por fim uma passagem de formatação:

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

Se `verify` responder "fail", o fluxo volta para `draft`, que desta vez já
vê a crítica através de `{{verify?}}`, em vez de simplesmente tentar de
novo às cegas. Se responder "pass", uma pessoa dá o aval antes de `publish`
sequer chegar a correr.

## Definir, correr e inspecionar

Um agente consegue definir e correr os seus próprios grafos diretamente
pela conversa (`manage_graph`, `run_graph`, `inspect_graph_run`), ou fazes
tu isso diretamente:

```bash
pepe graph import research.json                      # o ficheiro indica o próprio agente
pepe graph list --agent assistant                     # todos os grafos desse agente
pepe graph run assistant research-and-verify --input "os números do Q3"
pepe graph runs --agent assistant                     # todas as execuções, incluindo as pausadas
pepe graph inspect grun_a1b2c3d4                       # histórico completo de uma execução
```

A importação confirma a estrutura toda de uma vez: destinos desconhecidos,
um nó sem permissão para nomear determinado agente, uma ferramenta a que
um nó tenta chegar mas que o agente não tem de facto. Todos os problemas
encontrados são reportados de uma vez, não só o primeiro.

Uma execução que chega a um nó `human` volta com o estado `waiting_human` e
exatamente aquilo que foi perguntado. Resolve-a assim que a resposta
estiver pronta:

```bash
pepe graph resume grun_a1b2c3d4 "sim, publica"
```

Nada da execução se perde enquanto ela espera: fica parada exatamente onde
ficou, o tempo que for preciso.

## Correr numa agenda

```bash
pepe graph schedule assistant research-and-verify --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

É o mesmo mecanismo de um prompt ou de um flow [agendado](../scheduled/),
só que com outro tipo de trabalho por baixo. Um grafo agendado que pausa
num nó `human` continua à espera de uma pessoa: disparar a execução por um
temporizador não faz aparecer ninguém disponível para responder mais cedo.

<div class="note"><strong>Um verificador que nunca concorda não gira para sempre.</strong> Todo o grafo tem um orçamento de passos, 25 por omissão e até 100 se subires o limite, de modo que um ciclo de revisão que nunca converge falha de forma limpa assim que esgota esse orçamento, em vez de correr indefinidamente. E a confiança não se espalha pela execução inteira: um nó só passa a não confiável se realmente ler algo vindo de fora (uma página descarregada, um documento carregado), e é só essa chamada que perde as ferramentas pré-aprovadas. Um nó que lê apenas estado limpo corre com total confiança, mesmo numa execução em que outro ramo tenha tocado em algo externo.</div>
