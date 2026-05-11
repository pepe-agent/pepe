---
title: Aprendizado
description: Como um agente transforma conversas confiáveis em memória e habilidades duradouras, como ver o que ele aprendeu, e como manter esse conhecimento organizado.
---

## Transformando conversas em conhecimento

Um agente consegue transformar conversas em conhecimento duradouro por conta própria,
através do ciclo de "reflexão". Ele aprende apenas com conversas **confiáveis**, então o
papo de um cliente com um bot de atendimento nunca vira memória.

## Com quem um agente aprende

Quem conta como confiável é definido por uma lista de permissões `trainers`, uma por bot:

| `trainers` | O que significa |
|------------|-----------------|
| `["*"]` | Aprende com todo mundo. |
| `[]` | Não aprende com ninguém. É isso que um bot voltado ao cliente quer. |
| `[id1, id2]` | Aprende apenas com esses ids de usuário, que são os seus ids, os treinadores. |
| omitido ou `null` | O padrão, que é todo mundo. |

A convenção de listas de permissão é a mesma em todo o Pepe: `["*"]` é todos, `[]` é
ninguém, `[itens]` é exatamente aqueles, e omitido ou `null` é o padrão daquele campo.

```bash
pepe gateway telegram add support --token $T --agent helper --trainers none
# um bot voltado ao cliente que nunca aprende; o seu bot de DM (sem --trainers) continua aprendendo
```

Essa mesma lista é a que controla o comando `/learn` e a troca de modelo por canal. Veja
[Canais](../channels/) para saber onde `trainers` é configurado em cada conexão.

## Memória e habilidades, separadas

Depois de uma sessão confiável, o agente revisa a conversa e atualiza duas coisas, mantidas
separadas de propósito:

- **Memória** é sobre *você*, e vive em `USER.md`, `MEMORY.md` e `people.md`. Ela é mantida
  enxuta, então o agente consolida em vez de ir empilhando.
- **Habilidades** são sobre *técnica*. O revisor prefere atualizar uma habilidade existente e
  rica a criar uma nova e estreita.

A revisão é uma execução em segundo plano com as ferramentas restritas à gestão de arquivos e
habilidades. Ela não tem shell nem rede, então pode atualizar o workspace e nada além disso, e
a sessão ao vivo fica intocada. Ela dispara no `/compact`, na ociosidade (uns 90 segundos
depois do último turno) e sob demanda com **`/learn`** (Telegram e console).

## Vendo o que ele aprendeu: TimeLearn

O TimeLearn mostra o que um agente aprendeu, numa linha do tempo: habilidades (🧠) e entradas
de memória (📝), das mais novas para as mais antigas, com origem e data.

```bash
pepe timelearn assistant         # no terminal
```

A mesma linha do tempo é a aba **Learning** do painel, com um seletor de agente. A divisão de
trabalho é simples: o gerador (a reflexão) produz, e o TimeLearn exibe.

## Consolidação

A revisão por conversa mantém a memória enxuta no dia a dia, mas cada execução só enxerga a
própria sessão. Ao longo de muitas conversas, a memória de um agente ainda pode acumular
sobreposição.

**Consolidação** é uma passada de arrumação independente. O agente relê *toda* a sua memória
permanente e as suas habilidades, sem nenhuma conversa pela frente, e organiza tudo. Ele funde
duplicatas, descarta linhas obsoletas ou contraditas, e combina habilidades que se sobrepõem,
sem perder nenhum fato duradouro. Usa o mesmo revisor restrito, limitado a arquivos.

```bash
pepe learn consolidate assistant              # roda uma passada agora
pepe learn auto assistant                     # agenda para toda noite (padrão 0 3 * * *)
pepe learn auto assistant --at "0 */12 * * *" # ou um agendamento personalizado
pepe learn auto assistant --off               # desliga o agendamento
pepe learn status                             # quais agentes consolidam por agendamento
```

No painel, a aba **Learning** tem um botão **Consolidate now** e um interruptor **Nightly**. O
agendamento noturno é uma entrada gerenciada na página de [Tarefas agendadas](../scheduled/) (um
job `consolidate`), e cada passada é registrada como qualquer outra execução, então você pode
reproduzi-la nos Traces do painel. Veja [Painel](../dashboard/).
