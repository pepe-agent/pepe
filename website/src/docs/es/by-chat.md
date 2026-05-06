---
title: Gestionar por conversación
description: Permite que agentes confiables configuren Pepe desde conversaciones en lenguaje natural.
---

Los agentes confiables pueden gestionar Pepe desde una conversación cuando les concedes las herramientas de gestión correspondientes. Estas acciones están protegidas porque cambian el estado del runtime o exponen acceso.

## Administrar agentes

`can_manage` controla qué agentes puede administrar un agente (crear, editar,
reconfigurar, entrenar) mediante la herramienta `manage_agent`. Está cerrado por
defecto y su significado es preciso:

- Sin definir (`null`): el agente solo puede administrarse a sí mismo.
- Vacío (`[]`, definido con `--can-manage none`): no puede administrar a nadie, ni
  siquiera a sí mismo. Un hijo bloqueado, por ejemplo un agente de cara al cliente
  que no debe alterarse a sí mismo.
- Una lista de nombres: exactamente esos agentes, y ningún otro. Incluye su propio
  nombre para dejar que también se administre a sí mismo.
- `["*"]` (definido con `--can-manage "*"`): todos los agentes. Un superadministrador
  explícito.

Concede autoridad de gestión directamente:

```bash
pepe agent manage supervisor "*"
```

### Hazlo por chat

Un agente administrador usa `manage_agent` para dar forma a los agentes de su
alcance. Sus acciones son `list`, `get`, `create`, `set_persona`, `set_model`,
`add_tool`, `remove_tool` y `remember` (añade un hecho duradero a la memoria del
destino). Por ejemplo:

```text
Dale al agente de soporte la herramienta send_file y registra en su memoria que
los reembolsos superiores a 200 necesitan una persona.
```

El agente llama a `manage_agent` con `action: "add_tool"` y luego con
`action: "remember"`. Cada una de estas acciones pasa por la barrera de permisos: el
agente propone el cambio, tú lo autorizas y solo entonces se aplica. Un agente
también puede renombrarse a sí mismo con la herramienta aparte `rename_agent` ("De
ahora en adelante, llámate scout"), que mueve su directorio de espacio de trabajo y
surte efecto en el siguiente mensaje.
