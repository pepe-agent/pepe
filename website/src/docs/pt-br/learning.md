---
title: Aprendizado
description: Como um agente transforma conversas confiáveis em memória e habilidades que duram, como enxergar o que ele já aprendeu, e como manter esse conhecimento arrumado.
---

## Transformando conversa em conhecimento

Um agente aprende sozinho, através de um ciclo de "reflexão" que transforma conversas em conhecimento duradouro por conta própria. Só que ele só aprende com conversas **confiáveis**, então a conversa de um cliente com um bot de atendimento jamais vira memória.

## Quem conta como confiável

Isso é definido por uma lista de permissões chamada `trainers`, uma para cada bot:

| `trainers` | O que significa |
|------------|-----------------|
| `["*"]` | Aprende com todo mundo. |
| `[]` | Não aprende com ninguém, exatamente o que um bot voltado ao cliente precisa. |
| `[id1, id2]` | Aprende só com esses ids de usuário, os seus, os treinadores. |
| omitido ou `null` | O padrão: todo mundo. |

É a mesma convenção de lista de permissões usada em todo o Pepe: `["*"]` é todos, `[]` é ninguém, `[itens]` é exatamente aqueles, e deixar o campo de fora (ou usar `null`) volta ao padrão dele.

```bash
pepe gateway telegram add support --token $T --agent helper --trainers none
# um bot de cliente que nunca aprende; seu bot pessoal de DM (sem --trainers) continua aprendendo normalmente
```

É essa mesma lista que controla quem pode usar `/learn` e trocar de modelo por canal. Veja [Canais](../channels/) para saber onde `trainers` é configurado em cada conexão.

## Memória e habilidades não se misturam

Depois de uma sessão confiável, o agente relê a conversa e atualiza duas coisas mantidas separadas de propósito:

- **Memória** é sobre *você*: mora em `USER.md`, `MEMORY.md` e `people.md`, e fica enxuta porque o agente prefere consolidar a ir empilhando.
- **Habilidades** são sobre *técnica*: o revisor prefere enriquecer uma habilidade já existente a criar uma nova e estreita.

Para achar algo pontual sem precisar ler o arquivo inteiro, o agente conta com a ferramenta `memory_search`: uma busca simples, sem diferenciar maiúsculas de minúsculas, nas próprias entradas de `MEMORY.md`, `USER.md` e `people.md`, cada resultado já indicando de qual arquivo veio. Ela procura as palavras em si, não o sentido delas, sem fazer nenhuma chamada a modelo ou a API, então não custa nada nem atrasa nada: o encaixe certo para uma memória mantida pequena de propósito.

Essa revisão roda em segundo plano, com acesso restrito só à gestão de arquivos e habilidades, sem shell e sem rede: ela mexe no workspace e em mais nada, deixando a sessão ativa completamente intocada. Ela dispara em três momentos: no `/compact`, na ociosidade (uns 90 segundos depois do último turno), e sob demanda com **`/learn`** (no Telegram e no console).

## Enxergando o que foi aprendido: o TimeLearn

O TimeLearn põe numa linha do tempo tudo o que um agente aprendeu, habilidades (🧠) e entradas de memória (📝), das mais recentes para as mais antigas, cada uma com sua origem e data.

```bash
pepe timelearn assistant         # no terminal
```

Essa mesma linha do tempo aparece na aba **Learning** do painel, com um seletor de agente. A divisão de trabalho é simples: quem produz é a reflexão, quem exibe é o TimeLearn.

## Consolidação

A revisão de cada conversa já mantém a memória enxuta no dia a dia, mas cada execução só enxerga a própria sessão. Depois de muitas conversas, ainda dá para acumular sobreposição na memória de um agente.

Por isso existe a **consolidação**, uma faxina independente: sem nenhuma conversa pela frente, o agente relê *toda* a sua memória e habilidades permanentes e organiza tudo, fundindo duplicatas, descartando linhas obsoletas ou contraditórias e combinando habilidades que se sobrepõem, sem perder nenhum fato duradouro pelo caminho. Usa esse mesmo revisor restrito a arquivos.

```bash
pepe learn consolidate assistant              # roda uma passada agora
pepe learn auto assistant                     # agenda para toda noite (padrão 0 3 * * *)
pepe learn auto assistant --at "0 */12 * * *" # ou um horário personalizado
pepe learn auto assistant --off               # desliga o agendamento
pepe learn status                             # quais agentes consolidam por agendamento
```

No painel, a aba **Learning** traz um botão **Consolidate now** e um interruptor **Nightly**. O agendamento noturno vira uma entrada gerenciada na página de [Tarefas agendadas](../scheduled/) (um job `consolidate`), e cada passada fica registrada como qualquer outra execução, disponível para reprodução nos Traces do painel. Veja [Painel](../dashboard/).
