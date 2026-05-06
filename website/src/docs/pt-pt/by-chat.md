---
title: Gerir pela conversa
description: Permite que agentes de confiança configurem o Pepe em conversas em linguagem natural.
---

Agentes de confiança podem gerir o Pepe pela conversa quando recebem as ferramentas de gestão correspondentes. Estas ações são protegidas porque alteram o estado do runtime ou libertam acesso.

## Administrar agentes

`can_manage` controla que agentes um agente pode administrar (criar, editar,
reconfigurar, treinar) através da ferramenta `manage_agent`. É fechado por
predefinição e o seu significado é preciso:

- Por definir (`null`): o agente só pode administrar-se a si próprio.
- Vazio (`[]`, definido com `--can-manage none`): não pode administrar ninguém, nem
  sequer a si próprio. Um filho bloqueado, por exemplo um agente virado para o
  cliente que não se deve alterar.
- Uma lista de nomes: exatamente esses agentes, e mais nenhum. Inclui o próprio nome
  para o deixar administrar-se também a si próprio.
- `["*"]` (definido com `--can-manage "*"`): todos os agentes. Um superadministrador
  explícito.

Concede autoridade de gestão diretamente:

```bash
pepe agent manage supervisor "*"
```

### Fá-lo pela conversa

Um agente administrador usa `manage_agent` para moldar os agentes do seu âmbito. As
suas ações são `list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`,
`remove_tool` e `remember` (acrescenta um facto duradouro à memória do alvo). Por
exemplo:

```text
Dá ao agente de apoio a ferramenta send_file e regista na memória dele que
reembolsos acima de 200 precisam de uma pessoa.
```

O agente chama `manage_agent` com `action: "add_tool"` e depois com
`action: "remember"`. Cada uma destas ações tem barreira: o agente propõe a
alteração, tu autoriza-la e só então é aplicada. Um agente também se pode renomear
com a ferramenta separada `rename_agent` ("De agora em diante, chama-te scout"), que
move o diretório do seu workspace e entra em vigor na próxima mensagem.
