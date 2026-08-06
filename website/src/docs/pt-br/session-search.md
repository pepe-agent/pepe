---
title: Busca de sessões
description: Seu agente consegue procurar e ler conversas passadas sozinho, usando os mesmos traces que você já pode inspecionar.
---

A memória de trabalho de um agente sobre uma conversa só dura enquanto essa conversa está rodando: quando a sessão termina ou a aplicação reinicia, ela se vai. O que sobrevive é o [trace](../traces/) de cada turno, um registro durável guardado no SQLite, esteja ou não a sessão que o criou ainda rodando.

A ferramenta `session_search` deixa o agente buscar e ler esse histórico sozinho, então você nunca precisa colar o contexto antigo de volta. Ela é sempre segura (sem pedido de permissão, a mesma postura de `read_file`) e só enxerga o projeto do próprio agente que a chamou: as conversas de um projeto nunca podem ser buscadas a partir de outro.

**Dentro desse projeto, até onde uma chamada realmente enxerga depende do `session_search_scope` do agente.** O padrão, `"self"`, significa que toda ação alcança apenas o histórico da própria conversa que está chamando. Essa é a configuração segura para um agente que atende vários clientes finais diferentes: um cliente pedindo "busca minhas conversas antigas" nunca pode conseguir ler as de outro cliente. Amplie para `"project"` (uma caixa de seleção na página de edição do agente, ou a flag `session_search_project_wide` do `manage_agent`) só para um agente com um único operador ou equipe do outro lado, uma ferramenta interna onde não existe conversa de mais ninguém no mesmo projeto para vazar.

## O que ela faz

- **`list_sessions`**: quais conversas aconteceram nesse projeto, as mais recentemente ativas primeiro, cada uma com sua contagem de turnos.
- **`search`**: encontra conversas cujo prompt ou atividade de ferramenta menciona uma palavra ou frase.
- **`session_history`**: todo turno registrado para uma chave de sessão, em ordem. A linha do tempo de uma conversa.
- **`show`**: a transcrição completa de um turno, com cada chamada de ferramenta, resultado e a resposta final.

```
Você: A gente já não tinha resolvido aquele problema da fatura da Acme umas semanas atrás?

Agente: [session_search search: "fatura Acme"]
Sim - no dia 3 de julho eu encontrei a fatura de maio deles com a alíquota de
imposto errada e corrigi. Quer que eu confira se aconteceu de novo esse mês?
```

Isso é busca, não memória: o agente só age sobre o que ele lê de volta na conversa atual. Nada encontrado desse jeito é assumido em silêncio; volta como texto que o agente lê e pode citar, igual a qualquer outro resultado de ferramenta.
