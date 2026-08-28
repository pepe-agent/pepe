---
title: Evals
description: Reproduz prompts que já correram bem no passado e confirma que o agente continua a responder e a usar as ferramentas da mesma forma.
---

Um **eval** volta a passar um prompt já conhecido por um agente e confere
tanto a resposta como as ferramentas que ele usou. É a tua rede de segurança
para o comportamento do agente: mudas um prompt, um modelo, ou o conjunto de
ferramentas, corres os evals, e sabes de imediato se alguma coisa que te
importava deixou de funcionar.

Isto importa porque um agente nunca devolve as mesmas palavras exatas duas
vezes seguidas, e um teste à espera de um texto fixo não serve de nada
aqui. Um eval verifica o que de facto conta: chamou a ferramenta certa?
Mencionou a resposta? Evitou dizer que não tinha acesso quando tinha?

## Os teus traces já são os dados de teste de que precisas

Escrever uma suite de evals é a parte difícil, correr é fácil, e ninguém
arranja tempo de tarde nenhuma para se sentar a escrever casos de teste.
Então a solução é não escrever nenhum: sempre que um agente resolver algo
bem, guarda essa execução tal como ela foi.

```bash
pepe eval add a1b2c3                                   # um id de trace
pepe eval add a1b2c3 --suite support --contains "refund,5 business days"
```

No painel, isto é um simples botão sobre o trace: **✓ Isto correu bem**.

### O que um caso verifica de facto

O caso guarda o prompt e a resposta do agente tal como aconteceram, e
verifica **as ferramentas que o agente usou naquele momento**. É essa a
asserção que compensa ter, porque sobrevive a atualizações de modelo e a
reformulações de texto, e é justamente o que muda quando uma edição corre
mal: o agente deixa de consultar as coisas e passa a inventá-las, ou
recorre à shell onde antes bastava ler um ficheiro. Um modelo que responde
à mesma pergunta usando as mesmas ferramentas é um modelo que continua a
funcionar tal como decidiste que devia funcionar.

Propositadamente, não exige de volta a mesma frase. Duas execuções do
mesmo prompt nunca produzem texto idêntico, e um teste teimoso nesse ponto
acaba silenciado ao fim de uma semana, deixando de proteger fosse o que
fosse a partir daí. A resposta que estava certa fica guardada no caso, sob
`recorded`, para quem quiser ler uma falha mais tarde. E se algumas
palavras dessa resposta *eram* mesmo o que importava, basta dizê-lo com
`--contains` para passarem também a ser verificadas.

Execuções falhadas nunca são aceites. Promover uma delas congelaria a
própria falha como se fosse a expectativa certa, entregando-te uma suite
toda verde só por causa disso.

## Como isto costuma correr, do início ao fim

Nunca escreveste um eval na vida e não é hoje que vais começar. Sem
problema, faz assim.

**1. Usa o Pepe normalmente.** Fala com o teu agente, deixa os clientes
falarem com ele. Toda a execução já fica registada sozinha, não precisas de
fazer nada de especial para isso acontecer.

**2. Quando algo correr bem, diz-lo.** Abre o painel, vai a
[Traces](../traces/), clica na execução em causa e carrega em **✓ Isto
correu bem**. É essa a cerimónia inteira. No terminal é igualzinho:

```bash
pepe traces                       # as execuções recentes, com os seus ids
pepe eval add a1b2c3              # guarda essa
# ✓ added to recorded: What is the price of the annual plan?
#   agent: support
#   asserts it still calls: read_file, web_search
#   run it with: pepe eval recorded
```

Repete isto umas quatro ou cinco vezes ao longo de uma semana, sempre que
notares o agente a fazer a coisa certa. No fim tens uma suite que descreve
o teu agente, escrita pelo próprio agente, sobre aquilo que os teus
clientes de facto perguntam.

**3. Antes de mudares o que quer que seja, corre a suite.**

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

Essa cruz é a razão de ser desta funcionalidade toda. O agente respondeu na
mesma. A resposta até parecia bem escrita. Só que deixou de abrir o
ficheiro e passou a recitar de memória, e no mês seguinte, quando o preço
mudasse, continuaria a citar o valor antigo com toda a confiança do mundo.
Nenhuma exceção foi lançada, nenhuma linha de log foi escrita, e sem esta
suite terias descoberto isto pela boca de um cliente.

**4. Mete-a a correr no CI.** Uma execução que não passa sai com um código
diferente de zero, por isso encaixa mesmo ao lado dos teus testes normais.
A partir daí, uma edição de persona que estrague alguma coisa já não chega
à produção sem ninguém dar por isso.

<div class="note"><strong>Quando um caso deixa de fazer sentido, apaga-o.</strong> São só ficheiros JSON dentro de <code>~/.pepe/evals/</code>. Um caso que já não reflete o que queres é para remover, não para discutir. A suite é um registo de decisões, e as decisões mudam com o tempo.</div>

## Correr

```bash
pepe eval                              # corre todas as suites (nativas + as tuas)
pepe eval arithmetic                   # corre uma suite
pepe eval arithmetic --models a,b,c    # ...contra vários modelos, lado a lado
pepe eval list                         # lista as suites e a contagem de casos
pepe eval add TRACE_ID                 # guarda uma execução que correu bem (ver acima)
pepe eval --seed                       # copia as suites nativas para ~/.pepe/evals, para editares
pepe eval help
```

Cada caso corre um turno real contra um modelo real, por isso os evals
precisam de um modelo configurado para funcionar. Uma execução imprime um
visto ou uma cruz por caso, com o motivo quando falha, e um total no fim.
Uma execução que não passa sai com um código diferente de zero, o que
chega para se encaixar em qualquer CI.

`--models a,b,c` corre a mesma suite (ou todas, se omitires o nome) contra
cada uma dessas ligações de modelo, e imprime a contagem de aprovados e
reprovados por modelo. É essa a forma de responderes à pergunta "devemos
mudar de modelo" com casos reais em vez de um palpite. A substituição só
vale para essa chamada em particular; a configuração de nenhum agente é
tocada.

## Suites que já vêm com o Pepe

Estas correm contra o teu **agente predefinido**, já que os casos não
indicam nenhum `agent` específico, ou seja, contra aquele para onde `pepe
agent default` aponta. As suites de ferramentas partem do princípio de que
esse agente tem as ferramentas nativas correspondentes.

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
| `tool-judgment` | Responde diretamente a factos conhecidos e só recorre a uma ferramenta quando é mesmo preciso. |
| `prompt-injection` | Ignora instruções embutidas em dados (documentos, avaliações, e-mails). |
| `grounding` | Responde a partir do texto fornecido e admite quando a resposta não está lá. |
| `safety` | Não produz um payload nocivo nem fabrica uma fonte falsa. |
| `agent-boundaries` | Admite que não consegue fazer algo (mover dinheiro, alcançar um agente desconhecido) em vez de fabricar sucesso. |

São **modelos de referência**: codificam expectativas razoáveis, não uma
verdade universal. Um modelo mais fraco, ou um agente com outro conjunto
de ferramentas, vai chumbar algumas, e é exatamente esse o objetivo. Corre
`pepe eval --seed` para as copiares para `~/.pepe/evals` e afinares os
prompts e as asserções aos teus próprios agentes.

## Escrever as tuas próprias

Uma suite é só um ficheiro JSON: uma lista de casos. Coloca as tuas em
`~/.pepe/evals/<nome>.json`. Um ficheiro aí **sobrepõe-se** a uma suite
nativa com o mesmo nome.

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

Todas as chaves de `expect` são opcionais, e um caso passa quando todas as
asserções presentes se verificam:

| Chave | Passa quando |
|---|---|
| `contains` | A resposta inclui cada uma destas strings (sem distinguir maiúsculas). |
| `not_contains` | A resposta não inclui nenhuma destas strings. |
| `matches` | A resposta corresponde a esta expressão regular (usa `(?i)` para ignorar maiúsculas). |
| `tool_called` | Estas ferramentas correram durante o turno. |
| `tool_not_called` | Estas ferramentas não correram durante o turno. |

Omite `agent` para correr o caso contra o agente predefinido, ou nomeia um
para fixares o caso nele.
