---
title: Agentes administradores
description: Deja que un agente gestione y entrene a otros con la herramienta manage_agent, dentro de un alcance can_manage dirigido.
---

Un agente puede administrar y **entrenar a otros agentes**. Con la herramienta
`manage_agent` define la persona, el modelo, las herramientas y la memoria de otro
agente, o crea agentes nuevos desde cero. La autoridad es una **lista de permisos
dirigida, por agente**, llamada `can_manage`, así que puedes tener varios
administradores a la vez, cada uno con alcance sobre un conjunto distinto de agentes.

## El alcance can_manage

| `can_manage` | Qué significa |
|--------------|---------------|
| ausente, o `nil` | Solo a sí mismo. Es el valor por defecto. |
| `[]` | A nadie, ni siquiera a sí mismo. Un agente de cliente bloqueado. |
| `[a, b]` | Exactamente esos agentes. Incluye su propio nombre para incluirse a sí mismo. |
| `["*"]` | Todos los agentes. Un superadministrador explícito. |

```bash
# boss pasa a administrar "sales"
pepe agent manage boss sales

# un superadministrador sobre todos los agentes
pepe agent manage boss "*"

# un agente bloqueado, que no puede modificarse a sí mismo
pepe agent add child --can-manage none
```

Igual que en el enrutamiento, `can_manage` es una lista dirigida y deliberadamente no es
simétrica. Dar a `boss` autoridad sobre `sales` no le concede a `sales` nada sobre
`boss`. La autoridad solo fluye en el sentido en que la escribiste, y eso es lo que te
permite poner un agente bloqueado, de cara al cliente, delante de un administrador sin
que el agente de cliente pueda reconfigurar al administrador ni a sí mismo.

## Qué hace manage_agent

| Acción | Qué hace |
|--------|----------|
| `list` | Lista los agentes del alcance. |
| `get` | Lee la configuración de un agente. |
| `create` | Crea un agente nuevo. |
| `set_persona` | Reescribe el prompt de sistema del agente objetivo. |
| `set_model` | Apunta al agente objetivo a otra conexión de modelo. |
| `set_utility_model` | Define la conexión barata donde corren las tareas menores del agente objetivo, como ponerle nombre a una conversación. Un valor vacío la desactiva, y esas tareas pasan a hacerse sin modelo. |
| `set_flag` | Activa o desactiva un interruptor del agente objetivo (`on`/`off`): `trust_untrusted_content` (dejar que actúe sobre lo que los desconocidos envían) o `exempt_message_limit`. Activar `trust_untrusted_content` no puede hacerse desde una ejecución que ella misma ha ingerido contenido de fuera, así que un documento inyectado no puede activarlo. |
| `add_tool` | Concede una herramienta más al agente objetivo. |
| `remove_tool` | Revoca una herramienta del agente objetivo. |
| `remember` | Añade un hecho a la memoria del agente objetivo. |

No necesitas los nombres técnicos de las flags. `set_flag` lo maneja el modelo, así que pides con tus palabras ("deja que el agente de soporte actúe sobre los archivos que envían los clientes", "deja de limitar los mensajes de este agente") y él elige el interruptor correcto.

La persona y la memoria viven en el workspace del agente objetivo. Las herramientas y el
modelo viven en su entrada del archivo de configuración.

## La barrera de permisos

`manage_agent` es una herramienta de riesgo, así que cada uso se autoriza a través de la
barrera de permisos. El agente propone el cambio, tú lo apruebas, y solo entonces se
escribe. Un agente solo puede tocar los agentes que están dentro de su propio alcance
`can_manage`, y una petición para administrar algo fuera de ese alcance se rechaza.
