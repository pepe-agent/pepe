---
title: Evals
description: Reproduza prompts que já funcionaram e confira se o agente continua respondendo e usando as ferramentas do mesmo jeito.
---

Um **eval** reproduz um prompt conhecido no agente e verifica a resposta e as ferramentas que ele usou para chegar lá. É a sua rede de segurança contra mudança de comportamento: altere um prompt, um modelo ou o conjunto de ferramentas, rode os evals, e descubra na hora se alguma coisa importante quebrou.

Isso importa porque um agente jamais responde a mesma pergunta duas vezes com as mesmas palavras exatas, então um teste que espera um texto fixo não serve para nada. O que um eval verifica é o que de fato importa: chamou a ferramenta certa? Mencionou a resposta correta? Não saiu dizendo que não tem acesso quando tem?

## Seus traces já são os dados de teste que faltavam

Escrever uma suíte de evals não é difícil de rodar, é difícil de *começar*, e ninguém nunca sobra uma tarde livre para isso. Então não escreva do zero. Sempre que o agente resolver bem alguma coisa, guarde essa execução:

```bash
pepe eval add a1b2c3                                   # um id de trace
pepe eval add a1b2c3 --suite support --contains "refund,5 business days"
```

No painel, isso vira um botão dentro do próprio trace: **✓ Isso deu certo**.

### O que o caso realmente verifica

O caso guarda o prompt e a resposta do agente ao pé da letra, mas o que ele de fato verifica são **as ferramentas usadas**. É essa a asserção que compensa ter: ela resiste a atualizações de modelo e a reformulações de texto, e é justamente o que muda quando uma edição sai errada, o agente para de consultar e passa a inventar, ou recorre ao shell onde antes só lia um arquivo. Um modelo que responde à mesma pergunta usando as mesmas ferramentas é um modelo que continua se comportando do jeito que você decidiu que deveria.

O que ele deliberadamente **não** exige é a mesma frase de volta. Duas execuções do mesmo prompt nunca saem idênticas, e um teste que insiste nisso acaba silenciado dentro de uma semana e, a partir daí, não protege mais nada. A resposta que estava boa fica registrada no caso, sob `recorded`, para quem precisar entender uma falha depois. Se alguma palavra ali *era* mesmo o ponto principal, basta declarar com `--contains` que ela também passa a ser verificada.

Execução que falhou é recusada de cara. Promovê-la congelaria o erro como se fosse a expectativa certa, e te entregaria uma suíte toda verde justamente por causa dele.

## Como isso funciona na prática, do começo ao fim

Você nunca escreveu um eval na vida e não vai ser hoje que vai sentar para escrever um do zero. Sem problema, siga estes passos.

**1. Use o Pepe normalmente.** Converse com o seu agente, deixe os clientes conversarem com ele. Toda execução já fica registrada sozinha, então não precisa fazer nada de especial para isso acontecer.

**2. Quando algo sair certo, marque.** Abra o painel, entre em [Traces](../traces/), clique na execução, aperte **✓ Isso deu certo**. É essa a cerimônia inteira. Pelo terminal é a mesma coisa:

```bash
pepe traces                       # as execuções recentes, com seus ids
pepe eval add a1b2c3              # guarda essa
# ✓ added to recorded: What is the price of the annual plan?
#   agent: support
#   asserts it still calls: read_file, web_search
#   run it with: pepe eval recorded
```

Repita isso umas quatro ou cinco vezes ao longo de uma semana, cada vez que perceber o agente fazendo a coisa certa. No fim você tem uma suíte que descreve o seu próprio agente, escrita pelo próprio agente, sobre o que os seus clientes de fato costumam perguntar.

**3. Antes de mudar qualquer coisa, rode a suíte.**

```bash
pepe eval recorded
```

```
▸ recorded
  ✓ What is the price of the annual plan?
  ✓ Cancel my subscription
  ✗ Where is my order?
      tool read_file was not called
  2/3 passed
```

Esse X ali é o motivo de existir a funcionalidade inteira. O agente ainda respondeu, e a resposta até que soava bem. Só que ele deixou de abrir o arquivo e passou a recitar de memória, e no mês seguinte, quando o preço mudasse, ele seguiria citando o valor antigo com toda a confiança do mundo. Nenhuma exceção foi levantada, nenhuma linha de log foi escrita, e sem essa suíte você só ia descobrir por reclamação de cliente.

**4. Bote a suíte no CI.** Uma execução que não passa sai com código de erro diferente de zero, então ela se encaixa direto ao lado dos seus outros testes. A partir daí, uma edição de persona que quebra alguma coisa deixa de chegar em produção sem ninguém notar.

<div class="note"><strong>Caso errado se apaga, não se discute.</strong> São só arquivos JSON em <code>~/.pepe/evals/</code>. Um caso que não reflete mais o que você quer é um caso para remover. A suíte é um registro de decisões, e decisões mudam com o tempo.</div>

## Rodando

```bash
pepe eval                              # roda todas as suítes (as nativas + as suas)
pepe eval arithmetic                   # roda uma suíte só
pepe eval arithmetic --models a,b,c    # ...contra vários modelos, lado a lado
pepe eval list                         # lista as suítes e a contagem de casos
pepe eval add TRACE_ID                 # guarda uma execução que deu certo (veja acima)
pepe eval --seed                       # copia as suítes nativas para ~/.pepe/evals, para você editar
pepe eval help
```

Cada caso roda um turno de verdade contra um modelo de verdade, então os evals precisam de um modelo já configurado. Uma execução imprime um certo ou um errado por caso, com o motivo quando falha, e fecha com um total. Como uma execução que não passa sai com código diferente de zero, ela se encaixa direto no CI.

`--models a,b,c` roda a mesma suíte, ou todas, se você não passar nenhum nome, contra cada uma dessas conexões de modelo, e mostra a contagem de aprovados e reprovados por modelo. É assim que se responde "devemos trocar de modelo" com casos reais, em vez de achismo. Essa troca vale só para aquela chamada específica; nenhuma configuração de agente é alterada por causa dela.

## Suítes que já vêm com o Pepe

Todas rodam contra o seu **agente padrão**, já que os casos não informam `agent`, ou seja, contra o que `pepe agent default` estiver apontando. As suítes de ferramentas partem do princípio de que esse agente tem as ferramentas nativas correspondentes.

| Suíte | O que verifica |
|---|---|
| `smoke` | Responde alguma coisa, ecoa, responde um fato básico sem soltar um falso "não consigo". |
| `arithmetic` | Somar, multiplicar, calcular porcentagem, um problema em forma de texto, um resultado negativo. |
| `reasoning` | Silogismo, sequência, a armadilha decimal do 9.9 contra 9.11, contagem de letras. |
| `knowledge` | Fatos estáticos (capital, planeta, chegada à Lua) sem inventar incerteza onde não há. |
| `formatting` | Resposta de uma palavra só, texto em maiúsculas, um objeto JSON pequeno, uma lista. |
| `language` | Responde no idioma pedido (pt / es / en) e também traduz. |
| `instruction-following` | Devolve só o que foi pedido, sim ou não estrito, restrição de contagem. |
| `tools-shell` | Realmente chama o `bash` e relata a saída dele. |
| `tools-web` | Chama `fetch_url` (lendo o example.com) e também `web_search`. |
| `tools-files` | Chama `write_file` / `read_file` / `list_dir` (escrevendo dentro de `/tmp`). |
| `tool-judgment` | Responde fatos conhecidos direto e só recorre a uma ferramenta quando é realmente necessário. |
| `prompt-injection` | Ignora instruções escondidas dentro dos dados (documentos, avaliações, e-mails). |
| `grounding` | Responde a partir do texto fornecido e admite quando a resposta não está ali. |
| `safety` | Não produz um payload nocivo e não inventa uma fonte falsa. |
| `agent-boundaries` | Admite que não consegue fazer algo (mover dinheiro, alcançar um agente desconhecido) em vez de fingir que conseguiu. |

Elas são **modelos de referência**: codificam expectativas razoáveis, não uma verdade universal. Um modelo mais fraco, ou um agente com outro conjunto de ferramentas, vai reprovar em algumas, e é exatamente esse o ponto. Rode `pepe eval --seed` para copiá-las para `~/.pepe/evals` e ajustar prompts e asserções aos seus próprios agentes.

## Escrevendo as suas próprias

Uma suíte é só um arquivo JSON com uma lista de casos. Coloque as suas em `~/.pepe/evals/<nome>.json`. Um arquivo ali **substitui** uma suíte nativa que tenha o mesmo nome.

```json
[
  {
    "name": "searches before answering a live question",
    "agent": "assistant",
    "prompt": "What is the USD to BRL rate right now?",
    "expect": {
      "contains": ["real"],
      "not_contains": ["i don't have access"],
      "matches": "\\d",
      "tool_called": ["web_search"],
      "tool_not_called": ["bash"]
    }
  }
]
```

Toda chave dentro de `expect` é opcional, e um caso passa quando todas as asserções presentes se confirmam:

| Chave | Passa quando |
|---|---|
| `contains` | A resposta inclui cada uma dessas strings (sem diferenciar maiúsculas de minúsculas). |
| `not_contains` | A resposta não inclui nenhuma dessas strings. |
| `matches` | A resposta bate com essa expressão regular (use `(?i)` para ignorar maiúsculas). |
| `tool_called` | Essas ferramentas rodaram durante o turno. |
| `tool_not_called` | Essas ferramentas não rodaram durante o turno. |

Omita `agent` para rodar o caso contra o agente padrão, ou informe um nome para fixar o caso naquele agente específico.
