---
title: Evals
description: Reproduz prompts conhecidos num agente e verifica a resposta e as ferramentas que ele usou.
---

Um **eval** reproduz um prompt conhecido num agente e faz asserções sobre a
resposta e sobre as ferramentas que o agente usou. É a tua rede de regressão para
comportamento: alteras um prompt, um modelo ou um conjunto de ferramentas, corres
os evals e vês de imediato se alguma coisa que te importava se partiu.

Isto importa porque os agentes não são determinísticos, por isso um teste de
string exata é inútil. Um eval verifica aquilo que de facto interessa. Chamou a
ferramenta certa? Mencionou a resposta? Evitou afirmar que não tem acesso?

## Os teus traces já são os dados de teste que tens

A parte difícil de uma suite de evals não é corrê-la, é *escrevê-la*, e ninguém
arranja a tarde para isso. Então não escrevas nenhuma. Quando o agente resolver
bem alguma coisa, guarda essa execução:

```bash
pepe eval add a1b2c3                                   # um id de trace
pepe eval add a1b2c3 --suite support --contains "refund,5 business days"
```

No painel, isto é um botão no trace: **✓ Isto correu bem**.

### O que o caso verifica de facto

O caso guarda o prompt e o agente tal e qual, e verifica **as ferramentas que o
agente usou**. É essa a asserção que vale a pena ter. Sobrevive a atualizações de
modelo e a reformulações do texto, e é exatamente aquilo que muda quando uma
edição corre mal: o agente deixa de consultar as coisas e começa a inventá-las, ou
recorre à shell onde antes lia um ficheiro. Um modelo que responde à mesma
pergunta com as mesmas ferramentas é um modelo que continua a funcionar como
decidiste que devia funcionar.

Deliberadamente **não** exige a mesma frase de volta. Duas execuções do mesmo
prompt nunca produzem uma frase igual, e um teste que insiste nisso é silenciado
ao fim de uma semana e, a partir daí, não protege coisa nenhuma. A resposta que
estava certa fica guardada no caso, em `recorded`, para quem for ler uma falha. Se
algumas palavras dela *eram* mesmo o ponto, di-lo com `--contains` e elas passam
também a ser verificadas.

As execuções falhadas são recusadas. Promover uma delas congelaria a falha como
expectativa e dar-te-ia uma suite verde precisamente para ela.

## Como isto corre, do início ao fim

Nunca escreveste um eval e não vais começar hoje. Tudo bem. Faz antes o seguinte.

**1. Usa o Pepe normalmente.** Fala com o teu agente, deixa os clientes falarem
com ele. Cada execução já está a ser registada, por isso não tens de fazer nada
para que isso aconteça.

**2. Quando algo correr bem, di-lo.** Abre o painel, vai a [Traces](../traces/),
carrega na execução e carrega em **✓ Isto correu bem**. É essa toda a cerimónia.
A partir do terminal é a mesma coisa:

```bash
pepe traces                       # as execuções recentes, com os seus ids
pepe eval add a1b2c3              # guarda aquela
# ✓ added to recorded: What is the price of the annual plan?
#   agent: support
#   asserts it still calls: read_file, web_search
#   run it with: pepe eval recorded
```

Faz isso quatro ou cinco vezes ao longo de uma semana, sempre que reparares que o
agente fez a coisa certa. Passas a ter uma suite que descreve o teu agente,
escrita pelo teu agente, sobre aquilo que os teus clientes perguntam de facto.

**3. Antes de mudares seja o que for, corre-a.**

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

Aquela cruz é o sentido inteiro da funcionalidade. O agente respondeu na mesma. A
resposta continuava a ler-se bem. Só que ele deixou de abrir o ficheiro e começou
a recitar de memória e, no mês seguinte, quando o preço mudasse, continuaria a
citar com toda a confiança o preço antigo. Nenhuma exceção foi levantada, nenhuma
linha de log foi escrita e, sem esta suite, terias sabido disto pela boca de um
cliente.

**4. Mete-a no CI.** Uma execução que não passa sai com código diferente de zero,
por isso entra logo ali ao lado dos teus testes. Assim, uma edição de persona que
parta alguma coisa não chega à produção em silêncio.

<div class="note"><strong>Quando um caso está errado, apaga-o.</strong> São ficheiros JSON sob <code>~/.pepe/evals/</code>. Um caso que já não reflete aquilo que queres é um caso a remover, não a discutir. A suite é um registo de decisões, e as decisões mudam.</div>

## Correr

```bash
pepe eval               # corre todas as suites (as nativas + as tuas)
pepe eval arithmetic    # corre uma suite
pepe eval list          # lista as suites e a contagem de casos
pepe eval add TRACE_ID  # guarda uma execução que correu bem (ver acima)
pepe eval --seed        # copia as suites nativas para ~/.pepe/evals, para editar
pepe eval help
```

Cada caso corre um turno real contra um modelo real, por isso os evals precisam de
um modelo configurado. Uma execução imprime um visto ou uma cruz por caso (com o
motivo, em caso de falha) e um total. Uma execução que não passa sai com código
diferente de zero, por isso encaixa no CI.

## Suites que vêm com o Pepe

Estas correm contra o teu **agente predefinido**, uma vez que os casos omitem o
`agent`, ou seja, contra aquele para onde `pepe agent default` aponta. As suites
de ferramentas assumem que esse agente tem as ferramentas nativas
correspondentes.

| Suite | O que verifica |
|---|---|
| `smoke` | Responde de todo, ecoa, responde a um facto básico sem um falso "não consigo". |
| `arithmetic` | Somar, multiplicar, percentagem, um problema em forma de texto, um resultado negativo. |
| `reasoning` | Silogismo, sequência, a armadilha decimal do 9.9 contra 9.11, contagem de letras. |
| `knowledge` | Factos estáticos (capital, planeta, chegada à Lua) sem incerteza inventada. |
| `formatting` | Respostas de uma palavra, maiúsculas, um pequeno objeto JSON, uma lista. |
| `language` | Responde no idioma pedido (pt / es / en) e traduz. |
| `instruction-following` | Devolve apenas o que foi pedido, sim/não estrito, restrições de contagem. |
| `tools-shell` | Chama mesmo o `bash` e relata a saída. |
| `tools-web` | Chama `fetch_url` (lê o example.com) e `web_search`. |
| `tools-files` | Chama `write_file` / `read_file` / `list_dir` (escreve sob `/tmp`). |
| `tool-judgment` | Responde diretamente a factos conhecidos e só recorre a uma ferramenta quando tem mesmo de o fazer. |
| `prompt-injection` | Ignora instruções embutidas em dados (documentos, avaliações, e-mails). |
| `grounding` | Responde a partir do texto fornecido e admite quando a resposta não está lá. |
| `safety` | Não produz um payload nocivo e não fabrica uma fonte falsa. |

São **modelos**: codificam expectativas razoáveis, não verdade universal. Um
modelo fraco ou um agente com outro conjunto de ferramentas vai chumbar algumas, e
é precisamente esse o ponto. Corre `pepe eval --seed` para as copiares para
`~/.pepe/evals` e afinares os prompts e as asserções aos teus próprios agentes.

## Escrever as tuas

Uma suite é um ficheiro JSON: uma lista de casos. Põe as tuas em
`~/.pepe/evals/<nome>.json`. Um ficheiro aí **sobrepõe-se** a uma suite nativa com
o mesmo nome.

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

Todas as chaves de `expect` são opcionais, e um caso passa quando se verificam
todas as asserções presentes:

| Chave | Passa quando |
|---|---|
| `contains` | A resposta inclui cada uma das strings (sem distinguir maiúsculas). |
| `not_contains` | A resposta não inclui nenhuma destas strings. |
| `matches` | A resposta corresponde a esta expressão regular (usa `(?i)` para ignorar maiúsculas). |
| `tool_called` | Estas ferramentas correram durante o turno. |
| `tool_not_called` | Estas ferramentas não correram durante o turno. |

Omite o `agent` para correr o caso contra o agente predefinido, ou nomeia um
agente para fixar o caso nele.
