---
title: Busca de sessões
description: O teu agente consegue procurar e ler conversas antigas sozinho, apoiado nos mesmos traces que já podes inspecionar.
---

A memória de trabalho de um agente sobre uma conversa só existe enquanto essa conversa
está a correr: assim que a sessão termina, ou a aplicação reinicia, desaparece. O que
fica mesmo é o [trace](../traces/) de cada turno, um registo durável em SQLite, quer a
sessão que o gerou continue viva ou não.

É a ferramenta `session_search` que deixa o agente procurar e ler esse histórico por
conta própria, sem que tu tenhas de voltar a colar contexto antigo. Não precisa de
pedido de permissão (a mesma postura do `read_file`), e só enxerga o projeto do
próprio agente que chama: as conversas de um projeto nunca ficam à vista a partir de
outro.

**Dentro desse projeto, o alcance de cada chamada depende do `session_search_scope`
do agente.** A predefinição, `"self"`, restringe cada ação ao histórico da própria
conversa que a chamou, e é a definição segura para um agente que atende vários
clientes diferentes: um cliente a pedir "procura nas minhas conversas antigas" jamais
pode acabar a ler as de outro. Só faz sentido alargar para `"project"` (uma caixa de
seleção na página de edição do agente, ou a flag `session_search_project_wide` do
`manage_agent`) quando há um único operador ou equipa do outro lado, uma ferramenta de
uso interno onde não existe conversa de mais ninguém, no mesmo projeto, que possa
vazar.

## O que consegue fazer

- **`list_sessions`**: que conversas já aconteceram neste projeto, começando pelas mais recentemente ativas, cada uma com a sua contagem de turnos.
- **`search`**: encontra conversas cujo prompt ou atividade de ferramenta mencione uma palavra ou frase.
- **`session_history`**: todos os turnos registados para uma chave de sessão, pela ordem em que aconteceram; a linha do tempo de uma conversa.
- **`show`**: a transcrição completa de um turno, com cada chamada de ferramenta, o respetivo resultado, e a resposta final.

```
Tu: Já não tínhamos resolvido aquele problema da fatura da Acme há umas semanas?

Agente: [session_search search: "fatura Acme"]
Sim, no dia 3 de julho encontrei a fatura de maio deles com a taxa de imposto
errada e corrigi. Queres que verifique se voltou a acontecer este mês?
```

Isto é pesquisa, não memória: o agente só age sobre aquilo que lê de volta para dentro
da conversa atual. Nada do que encontra desta forma fica assumido em silêncio; volta
sempre como texto que o agente lê e pode citar, tal como qualquer outro resultado de
ferramenta.
