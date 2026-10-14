---
title: Aprendizagem
description: Como um agente transforma conversas de confiança em memória e em competências duradouras, como consultar o que já aprendeu, e como manter esse conhecimento arrumado.
---

## Transformar conversas em conhecimento

Um agente consegue, sozinho, transformar conversas em conhecimento duradouro, através do ciclo de "reflexão". Só aprende com conversas **de confiança**, o que significa que a conversa de um cliente com um bot de apoio nunca vira memória.

## Com quem um agente aprende

Cada bot tem a sua própria lista de permissões `trainers`, e é ela que decide quem conta como sendo de confiança:

| `trainers` | O que significa |
|------------|-----------------|
| `["*"]` | Aprende com toda a gente. |
| `[]` | Não aprende com ninguém. Isto é o que um bot voltado para clientes costuma querer. |
| `[id1, id2]` | Aprende só com esses ids de utilizador, ou seja, contigo e com quem mais designares como treinador. |
| omitido ou `null` | A predefinição: toda a gente. |

Esta convenção de listas de permissões repete-se em todo o Pepe: `["*"]` é todos, `[]` é ninguém, `[itens]` é exatamente aqueles itens, e omitido ou `null` cai na predefinição do campo.

```bash
pepe gateway telegram add support --token $T --agent helper --trainers none
# um bot voltado para clientes que nunca aprende; o teu próprio bot de DM (sem --trainers) continua a aprender normalmente
```

É a mesma lista que controla o comando `/learn` e a troca de modelo por canal. Para veres onde se configura `trainers` em cada ligação, consulta [Canais](../channels/).

## Memória e competências, cada coisa no seu lugar

No fim de uma sessão de confiança, o agente revê a conversa e atualiza duas coisas que se mantêm sempre separadas de propósito:

- **Memória** é sobre *ti*: vive em `USER.md`, `MEMORY.md` e `people.md`, e é mantida enxuta porque o agente prefere consolidar a ir empilhando entradas novas.
- **`TOOLS.md`** é sobre *como as coisas se fazem aqui*: onde estão os teus dados e sistemas, que ferramenta ou serviço trata de cada trabalho e a receita por trás de um resultado que correu bem (a ferramenta, o prompt, o estilo, os ficheiros de referência, o script). É carregado em todas as conversas, por isso o agente já começa a saber, sem depender de se lembrar de ir ver. O agente escreve nele assim que algo resulta, e não só na revisão em segundo plano. Nunca guarda palavras-passe nem tokens, apenas onde estão guardados.
- **Competências** são sobre *técnica*: quando pode, o revisor prefere enriquecer uma competência já existente a criar uma nova e estreita.

Para localizar uma coisa em concreto sem ter de ler o ficheiro inteiro, o agente conta com a ferramenta `memory_search`: uma pesquisa sobre as entradas das suas próprias notas (`MEMORY.md`, `USER.md`, `people.md`, `TOOLS.md` e qualquer outra que mantenha), cada resultado já assinalado com o ficheiro de onde saiu. Compara palavra a palavra, sem distinguir maiúsculas nem acentos, e ordena as entradas pelo número de palavras que coincidem. Procura as palavras em si, não o significado por trás delas, e não faz qualquer chamada a modelo ou a API, o que a torna gratuita e instantânea, exatamente o que convém a uma memória mantida pequena de propósito.

O `TOOLS.md` é carregado em todas as conversas. O `MEMORY.md` e o `USER.md` só entram numa conversa privada que possa alimentar o que o agente guarda (o painel, a API, o terminal, um editor, um chat um a um no Telegram com alguém de quem o bot aprende), porque falam de uma pessoa e a sessão de um grupo é de todos os que lá estão. Um visitante anónimo do widget ou um cliente de um bot de atendimento nunca os recebe, e também não é instruído a gravar notas. Quando um turno exigiu tentativa e erro até funcionar, o agente recebe também um lembrete de uma linha, só nessa chamada ao modelo, para gravar a receita no `TOOLS.md` antes de responder. Cada ficheiro é cortado aos 20 000 caracteres e os três juntos aos 40 000; quando algo é cortado, o prompt avisa. O diário de hoje e o de ontem (`memory/AAAA-MM-DD.md`, escrito pela mesma revisão) carregam em conjunto, e o `memory_search` lê todos os dias. Quando as notas passam dos 10 000 caracteres, ou os diários antigos se acumulam, a consolidação corre sozinha, no máximo uma vez por dia: uma entrada por tipo de tarefa, tentativas falhadas descartadas e diários antigos incorporados nas notas permanentes. O `mix pepe agent footprint` mostra quanto custam.

A própria revisão corre em segundo plano, com as ferramentas reduzidas à gestão de ficheiros e competências: sem shell, sem rede, capaz de mexer no workspace e mais nada, deixando a sessão em curso completamente intocada. Dispara em três situações: no `/compact`, na inatividade (cerca de 90 segundos após o último turno) e a pedido, com **`/learn`** (disponível no Telegram e na consola).

## Ver o que já aprendeu: o TimeLearn

O TimeLearn apresenta o que um agente aprendeu ao longo do tempo, numa linha temporal com competências (🧠) e entradas de memória (📝), das mais recentes para as mais antigas, cada uma com a sua origem e data.

```bash
pepe timelearn assistant         # no terminal
```

Essa mesma linha temporal existe no painel, no separador **Learning**, com um seletor de agente. A divisão de tarefas aqui é simples: quem produz é o gerador (a reflexão); quem mostra é o TimeLearn.

## Consolidação

A revisão feita a cada conversa vai mantendo a memória enxuta no imediato, mas cada uma dessas execuções só enxerga a sua própria sessão. Ao fim de muitas conversas, mesmo assim, a memória de um agente pode acabar por acumular repetições.

A **consolidação** existe justamente para essa arrumação, à parte: o agente relê toda a sua memória e competências permanentes, sem nenhuma conversa à sua frente, e trata de as pôr em ordem. Funde o que está duplicado, descarta o que ficou obsoleto ou contraditório, junta competências que se sobrepõem, e faz tudo isto sem perder um único facto duradouro. Usa o mesmo revisor restrito, limitado a ficheiros, da secção anterior.

```bash
pepe learn consolidate assistant              # corre uma passagem agora
pepe learn auto assistant                     # agenda-a para todas as noites (predefinição 0 3 * * *)
pepe learn auto assistant --at "0 */12 * * *" # ou um horário à tua escolha
pepe learn auto assistant --off               # desliga o agendamento
pepe learn status                             # que agentes têm consolidação agendada
```

No painel, o separador **Learning** tem um botão **Consolidate now** e um interruptor **Nightly**. Esse agendamento noturno é uma entrada gerida na página de [Tarefas agendadas](../scheduled/) (um job do tipo `consolidate`), e fica registado como qualquer outra execução, por isso podes revê-lo mais tarde nos Traces do painel. Ver [Painel](../dashboard/).
