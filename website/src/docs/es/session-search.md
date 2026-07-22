---
title: Búsqueda de sesiones
description: Un agente puede encontrar y leer conversaciones pasadas, usando los mismos traces duraderos que ya puedes inspeccionar.
---

La propia memoria de un agente sobre una conversación vive solo en el proceso activo de esa conversación - cuando la sesión termina o la aplicación se reinicia, esa memoria desaparece. Lo que sobrevive es el [trace](../traces/) de cada turno: un registro duradero, guardado en SQLite, que se mantiene sin importar si la sesión que lo creó sigue en marcha.

La herramienta `session_search` le da al agente una forma de buscar y leer ese historial directamente, sin que tengas que volver a pegar el contexto antiguo. Es siempre segura (sin aviso de permiso, la misma postura que `read_file`), y está limitada al propio proyecto del agente que la llama - las conversaciones de un proyecto no son para buscar en otro.

**Dentro de ese proyecto, hasta dónde llega realmente una llamada depende del `session_search_scope` del agente.** Por defecto (`"self"`), cada acción solo alcanza el historial de la propia conversación que la llama - la configuración segura para un agente que habla con varios clientes finales distintos, donde un cliente pidiendo "busca mis conversaciones anteriores" nunca debe poder leer las de otro. Amplíalo a `"project"` (una casilla en la página de edición del agente, o el flag `session_search_project_wide` de `manage_agent`) solo para un agente que habla con un único operador/equipo - una herramienta interna sin ninguna conversación ajena en el mismo proyecto que pueda filtrarse.

## Qué puede hacer

- **`list_sessions`** - qué conversaciones han ocurrido en este proyecto, las más recientemente activas primero, cada una con su número de turnos.
- **`search`** - encuentra conversaciones cuyo prompt o actividad de herramienta menciona una palabra o frase dada.
- **`session_history`** - cada turno registrado para una clave de sesión, en orden - la línea temporal de una conversación.
- **`show`** - la transcripción completa de un turno: cada llamada a herramienta, resultado, y la respuesta final.

```
Tú: ¿No habíamos resuelto ya ese problema de la factura de Acme hace unas semanas?

Agente: [session_search search: "factura Acme"]
Sí - el 3 de julio encontré que su factura de mayo tenía mal la tasa de
impuesto y la corregí. ¿Quieres que revise si volvió a pasar este mes?
```

Esto es búsqueda, no memoria: el agente solo actúa sobre lo que lee de vuelta en la conversación actual. Nada de lo encontrado así se asume en silencio - vuelve como texto que el agente lee y puede citar, igual que cualquier otro resultado de herramienta.
