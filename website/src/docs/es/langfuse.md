---
title: Langfuse
description: Envía las ejecuciones de los agentes a Langfuse para observabilidad, y gestiona la persona de un agente desde un prompt de Langfuse en lugar de config.json.
---

## Langfuse

[Langfuse](https://langfuse.com) es una conexión opcional, no un requisito:
nada en Pepe asume que está ahí. Dos funciones lo usan:

- **Exportación de traces**: cada ejecución terminada se envía a Langfuse
  como un trace OTLP, para que puedas explorar, depurar y evaluar
  ejecuciones ahí.
- **Prompts gestionados**: la persona de un agente se obtiene de un prompt
  que editas en Langfuse, en lugar de `system_prompt`/`SOUL.md`. Opt-in por
  agente, además de las credenciales de abajo, mediante `langfuse_prompt`.

### Credenciales

Ambas funciones leen las mismas variables de entorno que usa cualquier SDK
oficial de Langfuse, así que credenciales ya configuradas para otra
herramienta funcionan aquí también:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
# Solo si no estás en cloud.langfuse.com:
export LANGFUSE_BASE_URL=https://tu-langfuse-self-hosted.ejemplo.com
```

Obtén el par de claves en la configuración de tu proyecto en Langfuse.
Definirlo activa la exportación de traces de inmediato, para todos los
agentes (mira abajo si además quieres prompts gestionados desde Langfuse, o
traces yendo a otro sitio). Una caída de Langfuse o una clave incorrecta hace
que la exportación de traces caiga silenciosamente a descartar el trace, y
que una obtención de `langfuse_prompt` caiga a la persona local del agente;
ninguna de las dos bloquea una conversación ni una ejecución.

Ambas funciones leen estas variables directamente del proceso de Pepe en
ejecución, no a través de la herramienta `bash` de un agente, algo que
importa si alguna vez le pides a un agente que ayude a depurar la conexión.
`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` tienen forma de secreto por su
nombre, así que Pepe las elimina de la shell del propio agente por defecto,
igual que cualquier otra credencial (ver [Secretos](../secrets/)). El agente
puede añadir él mismo los dos nombres a `secrets.expose_env` si necesita
comprobarlas directamente, solo ten en cuenta que una lectura de longitud 0
ahí significa "eliminada de mi shell", no "sin definir en el servidor".

### Exportación de traces

El par `LANGFUSE_*` de arriba ya basta por sí solo: la exportación de traces
se activa en cuanto `LANGFUSE_PUBLIC_KEY` y `LANGFUSE_SECRET_KEY` están
definidas, sin necesitar ninguna variable de OTEL aparte. Cada ejecución
terminada se convierte en un trace OTLP: un span raíz para toda la ejecución,
un span hijo por llamada a herramienta y por llamada a modelo, con atributos
genéricos de OpenTelemetry y los propios de Langfuse definidos en cada uno,
así que las sesiones se agrupan correctamente y las generaciones se
distinguen de los spans de herramienta normales.

Para enviar traces a otro sitio que no sea Langfuse (un colector
self-hosted, Honeycomb, cualquier otro backend que hable OTLP), define las
variables estándar de OTLP, y estas toman el control por completo (el par
`LANGFUSE_*` pasa entonces a usarse solo para prompts gestionados, si
también usas eso):

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://tu-colector.ejemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de usuario:contraseña>"
```

Detalle completo, incluyendo las dos variables extra de OTEL que rara vez
necesitas: [Traces](../traces/#enviar-traces-a-una-herramienta-de-observabilidad).

### Prompts gestionados

```bash
pepe agent add support --langfuse-prompt support-persona
```

Define el `langfuse_prompt` de un agente (la flag del CLI de arriba, o el
mismo campo en el editor de agente del panel) con el nombre de un prompt en
Langfuse, y la persona de ese agente pasa a obtenerse de ahí: edita el
prompt en Langfuse y el cambio llega a Pepe en pocos minutos, sin redeploy.
Es opt-in por agente; un agente sin `langfuse_prompt` definido queda
totalmente sin cambios, y uno cuya obtención falle (inaccesible, el nombre
no resuelve) simplemente usa la persona local, exactamente como si esto
nunca se hubiera configurado. Lee el par
`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` de arriba. Detalle completo:
[Agentes](../agents/#gestionar-una-persona-desde-langfuse).
