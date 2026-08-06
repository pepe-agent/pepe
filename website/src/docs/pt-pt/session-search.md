---
title: Busca de sessões
description: O teu agente consegue procurar e ler conversas passadas sozinho, usando os mesmos traces que já podes inspecionar.
---

A memória de trabalho de um agente sobre uma conversa só dura enquanto essa conversa está a correr: quando a sessão termina ou a aplicação reinicia, desaparece. O que sobrevive é o [trace](../traces/) de cada turno, um registo durável guardado em SQLite, esteja ou não a sessão que o criou ainda a correr.

A ferramenta `session_search` deixa o agente procurar e ler esse histórico sozinho, para nunca teres de colar o contexto antigo de volta. É sempre segura (sem pedido de permissão, a mesma postura de `read_file`) e só vê o projeto do próprio agente que a chamou: as conversas de um projeto nunca podem ser procuradas a partir de outro.

**Dentro desse projeto, até onde uma chamada consegue ver depende do `session_search_scope` do agente.** A predefinição, `"self"`, significa que cada ação alcança apenas o histórico da própria conversa que está a chamar. É a definição segura para um agente que fala com vários clientes finais diferentes: um cliente a pedir "procura as minhas conversas antigas" nunca pode conseguir ler as de outro cliente. Alarga para `"project"` (uma caixa de seleção na página de edição do agente, ou a flag `session_search_project_wide` do `manage_agent`) só para um agente com um único operador ou equipa do outro lado, uma ferramenta interna onde não há conversa de mais ninguém no mesmo projeto para vazar.

## O que faz

- **`list_sessions`**: que conversas aconteceram nesse projeto, as mais recentemente ativas primeiro, cada uma com a sua contagem de turnos.
- **`search`**: encontra conversas cujo prompt ou atividade de ferramenta menciona uma palavra ou frase.
- **`session_history`**: todos os turnos registados para uma chave de sessão, por ordem. A linha do tempo de uma conversa.
- **`show`**: a transcrição completa de um turno, com cada chamada de ferramenta, resultado e a resposta final.

```
Tu: Já não tínhamos resolvido aquele problema da fatura da Acme há umas semanas?

Agente: [session_search search: "fatura Acme"]
Sim - no dia 3 de julho encontrei a fatura de maio deles com a taxa de imposto
errada e corrigi. Queres que confirme se aconteceu outra vez este mês?
```

Isto é procura, não memória: o agente só age sobre o que lê de volta na conversa atual. Nada do que é encontrado desta forma é assumido em silêncio; volta como texto que o agente lê e pode citar, tal como qualquer outro resultado de ferramenta.
