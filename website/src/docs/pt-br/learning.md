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
- **`TOOLS.md`** é sobre *como as coisas são feitas aqui*: onde ficam seus dados e sistemas, qual ferramenta ou serviço faz cada trabalho e a receita por trás de um resultado que deu certo (a ferramenta, o prompt, o estilo, os arquivos de referência, o script). Ele é carregado em toda conversa, então o agente já começa sabendo, sem depender de lembrar de ir olhar. O agente escreve nele assim que algo funciona, e não só na revisão em segundo plano. Nunca guarda senha nem token, só onde ele está guardado.
- **Habilidades** são sobre *técnica*: o revisor prefere enriquecer uma habilidade já existente a criar uma nova e estreita.

Para achar algo pontual sem precisar ler o arquivo inteiro, o agente conta com a ferramenta `memory_search`: uma busca nas entradas das próprias anotações (`MEMORY.md`, `USER.md`, `people.md`, `TOOLS.md` e qualquer outra que ele mantenha), cada resultado já indicando de qual arquivo veio. Ela compara palavra por palavra, sem diferenciar maiúsculas nem acentos, e ordena as entradas por quantas palavras casam. Ela procura as palavras em si, não o sentido delas, sem fazer nenhuma chamada a modelo ou a API, então não custa nada nem atrasa nada: o encaixe certo para uma memória mantida pequena de propósito.

O `TOOLS.md` é carregado em toda conversa. O `MEMORY.md` e o `USER.md` só entram numa conversa privada que pode alimentar o que o agente guarda (o painel, a API, o terminal, um editor, um chat um a um no Telegram com alguém de quem o bot aprende), porque falam de uma pessoa e a sessão de um grupo é de todos que estão nele. Um visitante anônimo do widget ou um cliente de um bot de atendimento nunca os recebe, e também não é instruído a gravar anotações. Quando um turno exigiu tentativa e erro até funcionar, o agente também recebe um lembrete de uma linha, só naquela chamada ao modelo, para gravar a receita no `TOOLS.md` antes de responder. Cada arquivo é cortado em 20.000 caracteres e os três juntos em 40.000; quando algo é cortado, o prompt avisa. O diário de hoje e o de ontem (`memory/AAAA-MM-DD.md`, escrito pela mesma revisão) carregam junto, e o `memory_search` lê todos os dias. Quando as anotações passam de 10.000 caracteres, ou os diários antigos se acumulam, a consolidação roda sozinha, no máximo uma vez por dia: uma entrada por tipo de tarefa, tentativas que falharam descartadas e diários antigos incorporados às anotações permanentes. O `mix pepe agent footprint` mostra quanto eles custam.

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
