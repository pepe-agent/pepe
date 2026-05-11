---
title: Evals
description: Reproduza prompts conhecidos no agente e verifique a resposta e as ferramentas que ele usou.
---

Um **eval** reproduz um prompt conhecido no agente e faz asserções sobre a
resposta e sobre as ferramentas que o agente usou. É a sua rede de regressão para
comportamento: mude um prompt, um modelo ou o conjunto de ferramentas, rode os
evals e veja na hora se alguma coisa com que você se importava quebrou.

Isso importa porque agentes são não determinísticos, então um teste de string
exata é inútil. Um eval verifica o que realmente importa. Ele chamou a ferramenta
certa? Mencionou a resposta? Evitou dizer que não tem acesso quando tem?

## Seus traces já são os dados de teste que você tem

A parte difícil de uma suíte de evals não é rodá-la, é *escrevê-la*, e ninguém
nunca acha a tarde livre para isso. Então não escreva. Quando o agente resolver
bem alguma coisa, guarde aquela execução:

```bash
pepe eval add a1b2c3                                   # um id de trace
pepe eval add a1b2c3 --suite support --contains "refund,5 business days"
```

No painel, isso é um botão no trace: **✓ Isso deu certo**.

### O que o caso de fato verifica

O caso guarda o prompt e o agente literalmente, e verifica **as ferramentas que o
agente usou**. Essa é a asserção que vale a pena ter. Ela sobrevive a
atualizações de modelo e a reescritas do texto, e é exatamente o que muda quando
uma edição dá errado: o agente para de consultar as coisas e passa a inventá-las,
ou apela para o shell onde antes lia um arquivo. Um modelo que responde à mesma
pergunta com as mesmas ferramentas é um modelo que continua funcionando como você
decidiu que ele deveria funcionar.

Ele deliberadamente **não** exige a mesma frase de volta. Duas execuções do mesmo
prompt nunca produzem uma frase idêntica, e um teste que insiste nisso é silenciado
em uma semana, e a partir daí não protege mais nada. A resposta que estava certa
fica guardada no caso, em `recorded`, para quem for ler uma falha. Se algumas
palavras dela *eram* o ponto, diga isso com `--contains` e elas também passam a
ser verificadas.

Execuções que falharam são recusadas. Promover uma delas congelaria a falha como
expectativa e entregaria a você uma suíte verde justamente para ela.

## Como isso funciona na prática, do começo ao fim

Você nunca escreveu um eval e não vai começar hoje. Tudo bem. Faça o seguinte.

**1. Use o Pepe normalmente.** Converse com o seu agente, deixe os clientes
conversarem com ele. Toda execução já está sendo registrada, então você não
precisa fazer nada para isso acontecer.

**2. Quando algo der certo, diga isso.** Abra o painel, vá em
[Traces](../traces/), clique na execução e aperte **✓ Isso deu certo**. É toda a
cerimônia. Pelo terminal é a mesma coisa:

```bash
pepe traces                       # as execuções recentes, com seus ids
pepe eval add a1b2c3              # guarde aquela
# ✓ added to recorded: What is the price of the annual plan?
#   agent: support
#   asserts it still calls: read_file, web_search
#   run it with: pepe eval recorded
```

Faça isso quatro ou cinco vezes ao longo de uma semana, sempre que notar o agente
fazendo a coisa certa. Você agora tem uma suíte que descreve o seu agente,
escrita pelo seu agente, sobre as coisas que os seus clientes de fato perguntam.

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

Esse "X" é o sentido inteiro da funcionalidade. O agente ainda respondeu. A
resposta ainda parecia boa. Ele só deixou de abrir o arquivo e passou a recitar de
memória e, no mês que vem, quando o preço mudar, ele seguiria citando com toda
confiança o preço antigo. Nenhuma exceção foi levantada, nenhuma linha de log foi
escrita e, sem essa suíte, você descobriria pela boca de um cliente.

**4. Coloque a suíte no CI.** Uma execução que não passa sai com código diferente
de zero, então ela entra direto ao lado dos seus testes. Agora uma edição de
persona que quebra alguma coisa não chega à produção em silêncio.

<div class="note"><strong>Quando um caso está errado, apague-o.</strong> São arquivos JSON em <code>~/.pepe/evals/</code>. Um caso que não reflete mais o que você quer é um caso para remover, não para discutir. A suíte é um registro de decisões, e decisões mudam.</div>

## Executando

```bash
pepe eval               # roda todas as suítes (as nativas + as suas)
pepe eval arithmetic    # roda uma suíte
pepe eval list          # lista as suítes e a contagem de casos
pepe eval add TRACE_ID  # guarda uma execução que deu certo (veja acima)
pepe eval --seed        # copia as suítes nativas para ~/.pepe/evals, para editar
pepe eval help
```

Cada caso roda um turno real contra um modelo real, então os evals precisam de um
modelo configurado. Uma execução imprime um "V" ou um "X" por caso (com o motivo,
em caso de falha) e um total. Uma execução que não passa sai com código diferente
de zero, então ela se encaixa no CI.

## Suítes que já vêm com o Pepe

Elas rodam contra o seu **agente padrão**, já que os casos omitem o `agent`, ou
seja, contra aquele para o qual `pepe agent default` aponta. As suítes de
ferramentas assumem que esse agente tem as ferramentas nativas correspondentes.

| Suíte | O que verifica |
|---|---|
| `smoke` | Responde alguma coisa, ecoa, responde um fato básico sem um falso "não consigo". |
| `arithmetic` | Somar, multiplicar, porcentagem, um problema em forma de texto, um resultado negativo. |
| `reasoning` | Silogismo, sequência, a armadilha decimal do 9.9 contra 9.11, contagem de letras. |
| `knowledge` | Fatos estáticos (capital, planeta, chegada à Lua) sem incerteza inventada. |
| `formatting` | Respostas de uma palavra, maiúsculas, um pequeno objeto JSON, uma lista. |
| `language` | Responde no idioma pedido (pt / es / en) e traduz. |
| `instruction-following` | Devolve apenas o que foi pedido, sim/não estrito, restrições de contagem. |
| `tools-shell` | Chama de fato o `bash` e relata a saída. |
| `tools-web` | Chama `fetch_url` (lê o example.com) e `web_search`. |
| `tools-files` | Chama `write_file` / `read_file` / `list_dir` (escreve em `/tmp`). |
| `tool-judgment` | Responde fatos conhecidos direto e só recorre a uma ferramenta quando é preciso. |
| `prompt-injection` | Ignora instruções embutidas em dados (documentos, avaliações, e-mails). |
| `grounding` | Responde a partir do texto fornecido e admite quando a resposta não está nele. |
| `safety` | Não produz um payload nocivo e não inventa uma fonte falsa. |

Elas são **modelos**: codificam expectativas razoáveis, não verdade universal. Um
modelo fraco ou um agente com outro conjunto de ferramentas vai reprovar em
algumas, e é justamente esse o ponto. Rode `pepe eval --seed` para copiá-las para
`~/.pepe/evals` e ajustar os prompts e as asserções aos seus próprios agentes.

## Escrevendo as suas

Uma suíte é um arquivo JSON: uma lista de casos. Coloque as suas em
`~/.pepe/evals/<nome>.json`. Um arquivo ali **sobrepõe** uma suíte nativa de mesmo
nome.

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

Toda chave de `expect` é opcional, e um caso passa quando todas as asserções
presentes valem:

| Chave | Passa quando |
|---|---|
| `contains` | A resposta inclui cada uma das strings (sem diferenciar maiúsculas). |
| `not_contains` | A resposta não inclui nenhuma dessas strings. |
| `matches` | A resposta casa com esta expressão regular (use `(?i)` para ignorar maiúsculas). |
| `tool_called` | Estas ferramentas rodaram durante o turno. |
| `tool_not_called` | Estas ferramentas não rodaram durante o turno. |

Omita o `agent` para rodar o caso contra o agente padrão, ou nomeie um agente
para fixar o caso nele.
