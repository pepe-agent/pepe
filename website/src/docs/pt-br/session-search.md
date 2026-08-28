---
title: Busca em sessões
description: Seu agente consegue procurar e reler conversas passadas por conta própria, usando os mesmos traces que já dá para inspecionar.
---

A memória de trabalho de um agente sobre uma conversa dura só enquanto ela está
rolando: assim que a sessão termina, ou a aplicação reinicia, essa memória some. O que
fica registrado é o [trace](../traces/) de cada turno, um histórico durável, guardado
em SQLite, esteja a sessão que o gerou ainda viva ou não.

A ferramenta `session_search` deixa o próprio agente buscar e ler esse histórico
sozinho, sem que você precise colar contexto antigo de volta na conversa. Ela é
sempre segura para rodar (não pede permissão, no mesmo nível de `read_file`) e enxerga
apenas o projeto do agente que a chamou: conversas de um projeto jamais aparecem numa
busca feita a partir de outro.

**Dentro desse mesmo projeto, o alcance de cada chamada ainda depende do
`session_search_scope` configurado no agente.** No padrão, `"self"`, toda busca só
enxerga o histórico da própria conversa que está chamando. É a configuração segura
para um agente que atende vários clientes diferentes: quando um cliente pede "busca
minhas conversas antigas", ele nunca pode acabar lendo as de outro cliente. Só amplie
para `"project"` (uma caixa de marcar na página de edição do agente, ou a flag
`session_search_project_wide` do `manage_agent`) num agente que atende um único
operador ou uma única equipe, uma ferramenta interna onde não existe conversa alheia
no mesmo projeto correndo o risco de vazar.

## O que dá para fazer

- **`list_sessions`**: lista as conversas já acontecidas nesse projeto, da mais recente para trás, cada uma com sua contagem de turnos.
- **`search`**: acha conversas em que o prompt ou a atividade de alguma ferramenta menciona uma palavra ou frase.
- **`session_history`**: devolve, em ordem, todos os turnos registrados numa chave de sessão específica, a linha do tempo inteira daquela conversa.
- **`show`**: traz a transcrição completa de um turno só, com cada chamada de ferramenta, o resultado dela e a resposta final.

```
Você: A gente já não tinha resolvido aquele problema da fatura da Acme umas semanas atrás?

Agente: [session_search search: "fatura Acme"]
Sim, no dia 3 de julho encontrei a fatura de maio deles com a alíquota de imposto
errada e já corrigi na hora. Quer que eu confira se aconteceu de novo este mês?
```

Isso é busca, não memória automática: o agente só age sobre o que efetivamente lê de
volta na conversa atual. Nenhuma informação encontrada dessa forma é dada como certa
em silêncio; tudo volta como texto que o agente lê e pode citar, exatamente como
qualquer outro resultado de ferramenta.
