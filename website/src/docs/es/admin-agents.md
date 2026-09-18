---
title: Agentes administradores
description: Deja que un agente gestione y entrene a otros con la herramienta manage_agent, dentro de un alcance can_manage dirigido.
---

Un agente puede administrar y **entrenar a otros agentes**. Con la herramienta
`manage_agent` define la persona, el modelo, las herramientas y la memoria de otro
agente, o crea agentes nuevos desde cero. La autoridad se rige por una **lista de
permisos dirigida, por agente**, llamada `can_manage`: puedes tener varios
administradores a la vez, cada uno con alcance sobre un conjunto distinto de agentes.

## El alcance can_manage

| `can_manage` | Qué significa |
|--------------|---------------|
| ausente, o `nil` | Solo a sí mismo. Es el valor por defecto. |
| `[]` | A nadie, ni siquiera a sí mismo. Un agente de cliente bloqueado. |
| `[a, b]` | Exactamente esos agentes. Incluye su propio nombre si quieres que también se administre a sí mismo. |
| `["*"]` | Todos los agentes. Un superadministrador explícito. |

```bash
# boss pasa a administrar "sales"
pepe agent manage boss sales

# un superadministrador sobre todos los agentes
pepe agent manage boss "*"

# un agente bloqueado, que no puede modificarse a sí mismo
pepe agent add child --can-manage none
```

Igual que el enrutamiento, `can_manage` es una lista dirigida y no es simétrica a
propósito. Dar a `boss` autoridad sobre `sales` no le concede a `sales` nada sobre
`boss`: la autoridad corre en un solo sentido, el que tú escribiste. Eso es justo lo
que te permite poner un agente bloqueado de cara al cliente delante de un
administrador, sin que ese agente de cliente pueda reconfigurar al administrador ni
tocarse a sí mismo.

## Qué hace manage_agent

| Acción | Qué hace |
|--------|----------|
| `list` | Lista los agentes del alcance. |
| `get` | Lee la configuración de un agente. |
| `create` | Crea un agente nuevo. |
| `set_persona` | Reescribe el prompt de sistema del agente objetivo. |
| `set_model` | Apunta al agente objetivo a otra conexión de modelo. |
| `set_utility_model` | Define la conexión barata donde corren las tareas menores del agente objetivo, como ponerle nombre a una conversación. Con un valor vacío se desactiva, y esas tareas pasan a resolverse sin modelo. |
| `set_flag` | Activa o desactiva un interruptor del agente objetivo (`on`/`off`): `trust_untrusted_content` (dejarlo actuar sobre lo que envían los desconocidos), `exempt_message_limit`, `midrun_fold` (dejar que una corrección a mitad de turno dirija el turno en curso, en vez de hacerla esperar siempre; usa el `triage_model` si existe, o si no el propio modelo del agente, lo que cuesta una llamada extra por cada mensaje a mitad de turno), `commitments` (detectar un seguimiento que el agente prometió al terminar un turno y llevarle la cuenta, sin que nadie se lo pida), `session_search_project_wide` (dejar que `session_search` vea todas las conversaciones del proyecto del agente objetivo, no solo las de quien llama; consulta [Búsqueda de sesiones](../session-search/); para un agente que atiende a varios clientes finales distintos, lo correcto es dejarlo desactivado), o `capability_nudge` (dejarlo mencionar, en una frase corta justo después de resolver algo, una funcionalidad relacionada que de verdad encaje: Watches, tareas programadas, Goals, una skill instalada), o `skill_learning` (dejar que ofrezca, sin que nadie se lo pida, guardar como skill un procedimiento que acaba de resolver, o corregir una skill que siguió y que lo llevó por mal camino; solo lo ofrece, y no escribe nada sin un sí). |
| `add_tool` | Concede una herramienta más al agente objetivo. |
| `remove_tool` | Revoca una herramienta del agente objetivo. |
| `remember` | Añade un hecho a la memoria del agente objetivo. |

No hace falta memorizar los nombres de estas flags: `set_flag` lo interpreta el
modelo, así que basta con pedirlo en tus propias palabras ("deja que el agente de
soporte actúe sobre los archivos que le mandan los clientes", "deja de limitarle los
mensajes a este agente") y él elige el interruptor correcto.

La persona y la memoria viven en el workspace del agente objetivo. Las herramientas
y el modelo viven en su entrada dentro del archivo de configuración.

## La barrera de permisos

Como `manage_agent` es una herramienta de riesgo, cada uso pasa por la barrera de
permisos: el agente propone el cambio, tú lo apruebas, y solo entonces se escribe.
Un agente solo puede tocar los agentes que caen dentro de su propio alcance
`can_manage`; cualquier petición de administrar algo fuera de ese alcance se
rechaza.
