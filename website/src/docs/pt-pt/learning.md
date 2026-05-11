---
title: Aprendizagem
description: Como um agente transforma conversas de confiança em memória e competências duradouras, como ver o que aprendeu, e como manter esse conhecimento arrumado.
---

## Transformar conversas em conhecimento

Um agente consegue transformar conversas em conhecimento duradouro por si próprio, através
do ciclo de "reflexão". Aprende apenas com conversas **de confiança**, por isso a conversa
de um cliente com um bot de apoio nunca se torna memória.

## Com quem um agente aprende

Quem conta como sendo de confiança é definido por uma lista de permissões `trainers`, uma
por bot:

| `trainers` | O que significa |
|------------|-----------------|
| `["*"]` | Aprende com toda a gente. |
| `[]` | Não aprende com ninguém. É o que um bot voltado para o cliente quer. |
| `[id1, id2]` | Aprende apenas com esses ids de utilizador, que são os teus ids, os treinadores. |
| omitido ou `null` | A predefinição, que é toda a gente. |

A convenção das listas de permissões é a mesma em todo o Pepe: `["*"]` é todos, `[]` é
ninguém, `[itens]` é exatamente aqueles, e omitido ou `null` é a predefinição desse campo.

```bash
pepe gateway telegram add support --token $T --agent helper --trainers none
# um bot voltado para o cliente que nunca aprende; o teu bot de DM (sem --trainers) continua a aprender
```

Essa mesma lista é a que controla o comando `/learn` e a troca de modelo por canal. Vê
[Canais](../channels/) para saber onde se configura `trainers` em cada ligação.

## Memória e competências, separadas

Depois de uma sessão de confiança, o agente revê a conversa e atualiza duas coisas, mantidas
separadas de propósito:

- **Memória** é sobre *ti*, e vive em `USER.md`, `MEMORY.md` e `people.md`. É mantida enxuta,
  por isso o agente consolida em vez de ir empilhando.
- **Competências** são sobre *técnica*. O revisor prefere atualizar uma competência existente e
  rica a criar uma nova e estreita.

A revisão é uma execução em segundo plano com as ferramentas restritas à gestão de ficheiros e
competências. Não tem shell nem rede, por isso pode atualizar o workspace e mais nada, e a
sessão ao vivo fica intocada. Dispara no `/compact`, na inatividade (cerca de 90 segundos depois
do último turno) e a pedido com **`/learn`** (Telegram e consola).

## Ver o que aprendeu: TimeLearn

O TimeLearn mostra o que um agente aprendeu, numa linha temporal: competências (🧠) e entradas
de memória (📝), das mais recentes para as mais antigas, com origem e data.

```bash
pepe timelearn assistant         # no terminal
```

A mesma linha temporal é o separador **Learning** no painel, com um seletor de agente. A divisão
de trabalho é simples: o gerador (a reflexão) produz, e o TimeLearn mostra.

## Consolidação

A revisão por conversa mantém a memória enxuta ao longo do caminho, mas cada execução só vê a sua
própria sessão. Ao fim de muitas conversas, a memória de um agente pode ainda assim acumular
sobreposições.

**Consolidação** é uma passagem de arrumação independente. O agente relê *toda* a sua memória
permanente e as suas competências, sem nenhuma conversa à frente, e arruma-as. Funde duplicados,
descarta linhas obsoletas ou contraditas, e junta competências sobrepostas, sem perder nenhum
facto duradouro. Usa o mesmo revisor restrito, limitado a ficheiros.

```bash
pepe learn consolidate assistant              # corre uma passagem agora
pepe learn auto assistant                     # agenda-a para todas as noites (predefinição 0 3 * * *)
pepe learn auto assistant --at "0 */12 * * *" # ou um agendamento à tua medida
pepe learn auto assistant --off               # desliga o agendamento
pepe learn status                             # que agentes consolidam por agendamento
```

No painel, o separador **Learning** tem um botão **Consolidate now** e um interruptor **Nightly**.
O agendamento noturno é uma entrada gerida na página de [Tarefas agendadas](../scheduled/) (um job
`consolidate`), e cada passagem é registada como qualquer outra execução, por isso podes revê-la
nos Traces do painel. Vê [Painel](../dashboard/).
