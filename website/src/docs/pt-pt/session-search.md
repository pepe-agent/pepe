---
title: Busca de sessões
description: Um agente consegue encontrar e ler conversas passadas, usando os mesmos traces duráveis que já podes inspecionar.
---

A própria memória de um agente sobre uma conversa vive só no processo ativo dessa conversa - quando a sessão termina ou a aplicação reinicia, essa memória desaparece. O que sobrevive é o [trace](../traces/) de cada turno: um registo durável, guardado em SQLite, mantido independentemente de a sessão que o criou ainda estar a correr.

A ferramenta `session_search` dá ao agente uma forma de procurar e ler esse histórico diretamente, sem precisares de colar o contexto antigo de volta. É sempre segura (sem pedido de permissão, a mesma postura de `read_file`), e fica limitada ao projeto do próprio agente que a chamou - as conversas de um projeto não são para procurar noutro.

**Dentro desse projeto, até onde uma chamada consegue ver depende do `session_search_scope` do agente.** Por omissão (`"self"`), cada ação só alcança o histórico da própria conversa que está a chamar - a definição segura para um agente que fala com vários clientes finais diferentes, em que um cliente a pedir "procura as minhas conversas antigas" nunca pode acabar a ler as de outro. Alarga para `"project"` (uma caixa de seleção na página de edição do agente, ou a flag `session_search_project_wide` do `manage_agent`) só para um agente que fala com um único operador/equipa - uma ferramenta interna sem conversa de outra pessoa no mesmo projeto para vazar.

## O que faz

- **`list_sessions`** - que conversas aconteceram nesse projeto, as mais recentemente ativas primeiro, cada uma com a sua contagem de turnos.
- **`search`** - encontra conversas cujo prompt ou atividade de ferramenta menciona uma palavra ou frase.
- **`session_history`** - todo o turno registado para uma chave de sessão, por ordem - a linha do tempo de uma conversa.
- **`show`** - a transcrição completa de um turno: cada chamada de ferramenta, resultado, e a resposta final.

```
Tu: Já não tínhamos resolvido aquele problema da fatura da Acme há umas semanas?

Agente: [session_search search: "fatura Acme"]
Sim - no dia 3 de julho encontrei a fatura de maio deles com a taxa de imposto
errada e corrigi. Queres que confirme se aconteceu outra vez este mês?
```

Isto é procura, não memória: o agente só age sobre o que lê de volta na conversa atual. Nada encontrado desta forma é assumido em silêncio - volta como texto que o agente lê e pode citar, tal como qualquer outro resultado de ferramenta.
