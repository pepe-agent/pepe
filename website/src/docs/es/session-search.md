---
title: Búsqueda de sesiones
description: Tu agente puede buscar conversaciones pasadas por su cuenta, usando los mismos registros de traza que ya puedes consultar tú.
---

La memoria de trabajo de un agente sobre una conversación solo dura mientras esa
conversación sigue activa: en cuanto la sesión termina o la aplicación se reinicia,
desaparece. Lo que sí sobrevive es la [traza](../traces/) de cada turno, un registro
duradero guardado en SQLite que se conserva sin importar si la sesión que lo generó
sigue viva o no.

La herramienta `session_search` le permite a un agente buscar y leer ese historial por
su cuenta, así nunca tienes que volver a pegarle contexto antiguo a mano. Es siempre
segura de usar (no dispara aviso de permiso, igual que `read_file`), y solo alcanza el
propio proyecto del agente que la invoca: las conversaciones de un proyecto jamás quedan
disponibles para buscar desde otro.

**Dentro de ese mismo proyecto, hasta dónde llega en verdad cada llamada depende del
`session_search_scope` del agente.** El valor por defecto, `"self"`, hace que cada acción
solo alcance el historial de la propia conversación que la disparó, la opción segura para
un agente que atiende a distintos clientes finales: si un cliente te pide "busca en mis
conversaciones anteriores", jamás debería poder leer las de otro cliente. Amplíalo a
`"project"` (con una casilla en la página de edición del agente, o el flag
`session_search_project_wide` de `manage_agent`) solo cuando el agente trata con un único
operador o equipo, es decir, una herramienta interna donde no hay ninguna conversación
ajena en ese proyecto que pueda filtrarse.

## Qué puede hacer

- **`list_sessions`**: qué conversaciones ocurrieron en este proyecto, empezando por las
  más recientes, cada una con su cantidad de turnos.
- **`search`**: encuentra conversaciones cuyo prompt o actividad de herramientas
  menciona una palabra o frase dada.
- **`session_history`**: todos los turnos registrados de una sesión puntual, en orden;
  la línea de tiempo completa de esa conversación.
- **`show`**: la transcripción completa de un turno, con cada llamada a herramienta, su
  resultado, y la respuesta final.

```
Tú: ¿No habíamos resuelto ya lo de la factura de Acme hace unas semanas?

Agente: [session_search search: "factura Acme"]
Sí, el 3 de julio encontré que su factura de mayo tenía mal aplicada la tasa
de impuesto y la corregí. ¿Quieres que revise si volvió a pasar este mes?
```

Esto es búsqueda, no memoria: el agente igual solo actúa sobre lo que lee de vuelta en la
conversación en curso. Nada de lo que encuentra así se da por hecho en silencio; vuelve
como texto que el agente lee y puede citar, exactamente igual que el resultado de
cualquier otra herramienta.
