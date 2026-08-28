---
title: Langfuse
description: Envía las ejecuciones de tus agentes a Langfuse para observabilidad, y gestiona la persona de un agente desde un prompt de Langfuse en vez de config.json.
---

## Langfuse

[Langfuse](https://langfuse.com) es una integración opcional: nada en Pepe da por hecho que está conectada. Dos funciones la aprovechan cuando lo está:

- **Exportación de traces**: cada ejecución terminada llega a Langfuse como un trace OTLP, listo para explorar, depurar y evaluar ahí mismo.
- **Prompts gestionados**: en lugar de definir la persona de un agente con `system_prompt` o `SOUL.md`, la traes de un prompt que editas en Langfuse. Se activa por agente, además de las credenciales de abajo, con `langfuse_prompt`.

### Credenciales

Las dos funciones leen las mismas variables de entorno que usa cualquier SDK oficial de Langfuse, así que si ya las tienes configuradas para otra herramienta, funcionan aquí sin tocar nada:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
# Solo si no usas cloud.langfuse.com:
export LANGFUSE_BASE_URL=https://tu-langfuse-autoalojado.ejemplo.com
```

El par de claves lo sacas de la configuración de tu proyecto en Langfuse. En cuanto lo defines, la exportación de traces arranca para todos los agentes (más abajo ves cómo gestionar prompts también desde Langfuse, o mandar los traces a otro destino). Si Langfuse está caído o la clave es incorrecta, la exportación simplemente descarta el trace en silencio, y la obtención de un `langfuse_prompt` recae en la persona local del agente: ninguna de las dos cosas bloquea nunca una conversación ni una ejecución.

Ambas funciones leen estas variables directamente del proceso de Pepe en ejecución, no a través de la herramienta `bash` de un agente. Esto importa si alguna vez le pides a un agente que te ayude a depurar la conexión: `LANGFUSE_PUBLIC_KEY` y `LANGFUSE_SECRET_KEY` tienen forma de secreto por su nombre, así que Pepe las borra de la shell del agente por defecto, igual que cualquier otra credencial (ver [Secretos](../secrets/)). El propio agente puede añadir esos dos nombres a `secrets.expose_env` si necesita comprobarlos directamente; eso sí, una lectura de longitud cero ahí significa "borrada de mi shell", no "sin definir en el servidor".

### Exportación de traces

El par `LANGFUSE_*` de arriba basta por sí solo: la exportación se activa en cuanto `LANGFUSE_PUBLIC_KEY` y `LANGFUSE_SECRET_KEY` están definidas, sin necesitar ninguna variable de OTEL aparte. Cada ejecución terminada se convierte en un trace OTLP con un span raíz para toda la ejecución y un span hijo por cada llamada a herramienta y a modelo, con los atributos genéricos de OpenTelemetry y los propios de Langfuse en cada uno, de modo que las sesiones se agrupan bien y las generaciones quedan distinguidas de los spans de herramienta comunes.

Si prefieres mandar los traces a otro sitio que no sea Langfuse (un colector autoalojado, Honeycomb, cualquier backend que hable OTLP), define las variables estándar de OTLP y toman el control por completo. El par `LANGFUSE_*` queda entonces reservado solo para los prompts gestionados, si también los usas:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://tu-colector.ejemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de usuario:contraseña>"
```

Todo el detalle, incluidas las dos variables extra de OTEL que rara vez hacen falta, está en [Traces](../traces/#enviar-traces-a-una-herramienta-de-observabilidad).

### Prompts gestionados

```bash
pepe agent add support --langfuse-prompt support-persona
```

Define el `langfuse_prompt` de un agente (con la flag del CLI de arriba, o el mismo campo en el editor de agente del panel) apuntando a un nombre de prompt en Langfuse, y la persona de ese agente pasa a obtenerse de ahí. Edita el prompt en Langfuse y el cambio llega a Pepe en pocos minutos, sin ningún redeploy. Es opt-in por agente: uno sin `langfuse_prompt` definido no cambia en nada, y si la obtención falla (el servidor no responde, el nombre no existe) el agente simplemente usa su persona local, como si esto nunca se hubiera configurado. Lee el mismo par `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` de arriba. Más detalle en [Agentes](../agents/#gestionar-una-persona-desde-langfuse).
