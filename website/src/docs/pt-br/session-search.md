---
title: Busca de sessões
description: Um agente consegue encontrar e ler conversas passadas, usando os mesmos traces duráveis que você já pode inspecionar.
---

A própria memória de um agente sobre uma conversa vive só no processo ativo daquela conversa - quando a sessão termina ou a aplicação reinicia, essa memória se vai. O que sobrevive é o [trace](../traces/) de cada turno: um registro durável, guardado no SQLite, mantido independente de a sessão que o criou ainda estar rodando.

A ferramenta `session_search` dá ao agente um jeito de buscar e ler esse histórico diretamente, sem você precisar colar o contexto antigo de volta. Ela é sempre segura (sem pedido de permissão, a mesma postura de `read_file`), e fica restrita ao projeto do próprio agente que a chamou - as conversas de um projeto não são pra buscar de outro.

## O que ela faz

- **`list_sessions`** - quais conversas aconteceram nesse projeto, as mais recentemente ativas primeiro, cada uma com sua contagem de turnos.
- **`search`** - encontra conversas cujo prompt ou atividade de ferramenta menciona uma palavra ou frase.
- **`session_history`** - todo turno registrado para uma chave de sessão, em ordem - a linha do tempo de uma conversa.
- **`show`** - a transcrição completa de um turno: cada chamada de ferramenta, resultado, e a resposta final.

```
Você: A gente já não tinha resolvido aquele problema da fatura da Acme umas semanas atrás?

Agente: [session_search search: "fatura Acme"]
Sim - no dia 3 de julho eu encontrei a fatura de maio deles com a alíquota de
imposto errada e corrigi. Quer que eu confira se aconteceu de novo esse mês?
```

Isso é busca, não memória: o agente só age sobre o que ele lê de volta na conversa atual. Nada encontrado desse jeito é assumido em silêncio - volta como texto que o agente lê e pode citar, igual a qualquer outro resultado de ferramenta.
