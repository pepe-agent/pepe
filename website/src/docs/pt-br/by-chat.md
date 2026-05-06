---
title: Gerenciar pela conversa
description: Permita que agentes confiáveis configurem o Pepe em conversas em linguagem natural.
---

Agentes confiáveis podem gerenciar o Pepe pela conversa quando recebem as ferramentas de gestão correspondentes. Essas ações são protegidas porque mudam o estado do runtime ou liberam acesso.

## Administrar agentes

`can_manage` controla quais agentes um agente pode administrar (criar, editar,
reconfigurar, treinar) pela ferramenta `manage_agent`. É fechado por padrão e seu
significado é preciso:

- Sem definir (`null`): o agente pode administrar apenas a si mesmo.
- Vazio (`[]`, definido com `--can-manage none`): ele não pode administrar ninguém,
  nem a si mesmo. Um filho travado, por exemplo um agente voltado ao cliente que não
  pode se alterar.
- Uma lista de nomes: exatamente esses agentes, e nenhum outro. Inclua o próprio nome
  para deixar que ele também administre a si mesmo.
- `["*"]` (definido com `--can-manage "*"`): todos os agentes. Um superadministrador
  explícito.

Conceda autoridade de gestão diretamente:

```bash
pepe agent manage supervisor "*"
```

### Faça pela conversa

Um agente administrador usa `manage_agent` para moldar os agentes do seu escopo. Suas
ações são `list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`,
`remove_tool` e `remember` (anexa um fato duradouro à memória do alvo). Por exemplo:

```text
Dê ao agente de suporte a ferramenta send_file e registre na memória dele que
reembolsos acima de 200 precisam de uma pessoa.
```

O agente chama `manage_agent` com `action: "add_tool"` e depois com
`action: "remember"`. Cada uma dessas ações tem barreira: o agente propõe a mudança,
você a autoriza e só então ela é aplicada. Um agente também pode se renomear com a
ferramenta separada `rename_agent` ("De agora em diante, se chame scout"), que move o
diretório do seu workspace e entra em vigor na próxima mensagem.
