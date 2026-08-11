---
title: Langfuse
description: Envía las ejecuciones de los agentes a Langfuse para observabilidad, y gestiona la persona de un agente desde un prompt de Langfuse en lugar de config.json.
---

## Langfuse

[Langfuse](https://langfuse.com) es una conexión opcional, no un requisito -
nada en Pepe asume que está ahí. Dos funciones independientes lo usan, y
puedes activar una, las dos, o ninguna:

- **Exportación de traces**: cada ejecución terminada se envía a Langfuse
  como un trace OTLP, para que puedas explorar, depurar y evaluar
  ejecuciones ahí.
- **Prompts gestionados**: la persona de un agente se obtiene de un prompt
  que editas en Langfuse, en lugar de `system_prompt`/`SOUL.md`.

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
Ninguna de las dos funciones hace nada hasta que sus propias credenciales
estén definidas (ver abajo - la exportación de traces lee un par de
variables distinto, el estándar de OTEL); una caída de Langfuse o una clave
incorrecta solo hace que esa función en concreto caiga silenciosamente al
comportamiento local, nunca bloquea una conversación ni una ejecución.

### Exportación de traces

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://cloud.langfuse.com/api/public/otel
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de pk-lf-...:sk-lf-...>"
```

Estas son las variables estándar de OTLP/OTEL, no el par `LANGFUSE_*` de
arriba - el endpoint OTLP de Langfuse autentica con una cabecera
`Authorization` literal, base64 de `clave-pública:clave-secreta`. Cada
ejecución terminada se convierte en un trace OTLP: un span raíz para toda la
ejecución, un span hijo por llamada a herramienta y por llamada a modelo,
con atributos genéricos de OpenTelemetry y los propios de Langfuse
definidos en cada uno, así que las sesiones se agrupan correctamente y las
generaciones se distinguen de los spans de herramienta normales.
Desactivado a menos que definas `OTEL_EXPORTER_OTLP_ENDPOINT`; funciona
también con cualquier otro backend que hable OTLP, no solo Langfuse. Detalle
completo, incluyendo las dos variables extra de OTEL que rara vez
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
