---
title: Proyectos
description: Aísla a un cliente de otro para que una sola instalación atienda a varios clientes sin que sus datos se crucen jamás.
---

## Qué es un proyecto

Un proyecto es un muro entre clientes. Una sola instalación de Pepe puede atender a muchos clientes sin que nada cruce de uno a otro: ni archivos, ni enrutamiento, ni claves de modelo.

Cada cliente (tenant) es un proyecto, incluido el que traes de fábrica. Toda instalación nueva arranca con un único **proyecto por defecto** (slug `default`), y ese es el que usa cualquier comando en el que omitas `--project`. Si solo atiendes a un cliente, nada cambia para ti: los nombres de agente sin prefijo van al proyecto por defecto, así que no tienes que pensar en proyectos hasta que necesites un segundo. Crea uno nuevo solo cuando de verdad tengas que mantener a distintos clientes separados entre sí.

<div class="note"><strong>El proyecto por defecto es un proyecto normal.</strong> Aparece en <code>project list</code> como cualquier otro, se puede renombrar y tiene su propia facturación. No hay ningún ámbito "root" especial con reglas distintas: omitir <code>--project</code> simplemente recae en el proyecto por defecto.</div>

## El handle es la identidad

La identidad real de un agente es su **handle**. En el proyecto por defecto el handle es solo el nombre simple (`sales`); en cualquier otro proyecto queda calificado como `proyecto/nombre` (`acme/sales`). El mismo nombre simple puede repetirse en cada proyecto, así que `acme/sales` y `globex/sales` son dos agentes completamente distintos.

El handle es lo que direcciona todo: lo usan el enrutamiento, las sesiones y los vínculos con los canales. Por debajo, cada proyecto y cada agente también llevan un id interno estable, y es ese id (no el nombre, que puede cambiar) el que queda registrado en el enrutamiento, los permisos, los valores predeterminados y los vínculos de cron, bot y token. Renombrar un proyecto o un agente solo le cambia la etiqueta y mueve su directorio; cada referencia lo sigue, así que nada se queda colgando.

### Archivos

El workspace de un agente vive en `~/.pepe/projects/<slug>/agents/<nombre>/`, y el espacio compartido de su proyecto en `~/.pepe/projects/<slug>/shared/`. Dos agentes con el mismo nombre en proyectos distintos nunca escriben en el mismo directorio, y una ruta `shared/...` jamás se filtra hacia otro cliente. El proyecto por defecto sigue exactamente la misma disposición bajo su propio slug (`~/.pepe/projects/default/…`).

### Enrutamiento

`send_to_agent` nunca cruza la frontera de un proyecto. Un destino dado por su nombre simple se resuelve siempre a un agente dentro del propio proyecto de quien envía, y un bloqueo estricto rechaza cualquier ruta entre proyectos, aunque una lista de permisos la pida explícitamente.

### Modelos y claves

Un agente busca sus modelos primero dentro de su propio proyecto, y solo si no los encuentra recurre al proyecto por defecto. Eso permite que un proyecto fije claves de proveedor privadas que ningún otro proyecto puede ver, o que simplemente herede un proveedor global compartido. Ni el agente ni el modelo de un proyecto se ascienden nunca a predeterminado global, ni siquiera cuando son los primeros que se crean.

## Crear y usar un proyecto

```bash
pepe project add acme --description "Acme Inc"
pepe project add globex
pepe project list

# agentes, modelos y rutas aceptan --project
pepe model add llm  --project acme --base-url ... --api-key '${ACME_KEY}' --model ...
pepe agent add sales   --project acme --prompt "..." --can-message support
pepe agent add support --project acme --prompt "..."
pepe agent route sales support --project acme   # ambos se resuelven dentro de acme

pepe agent list --project acme    # solo los de Acme
pepe agent list                   # solo los del proyecto por defecto
pepe agent list --all             # todos los proyectos
pepe chat --project acme sales    # o: pepe run acme/sales "..."
```

## Renombrar y eliminar

```bash
pepe project rename acme umbrella   # le cambia la etiqueta y mueve su directorio;
                                    # todos los vínculos lo siguen, porque son por id
pepe project remove acme            # se niega mientras todavía tenga agentes
pepe project remove acme --force    # lo elimina, y se lleva sus agentes con él
```

Como las referencias son por id, renombrar un proyecto (o un agente) nunca rompe una ruta, un token, un cron ni un vínculo de bot. El nombre es solo una etiqueta; el id es lo que todo apunta de verdad.

## Cómo queda en la configuración

Los proyectos viven en un mapa `"projects"` indexado por un id estable; cada entrada lleva un `slug` y un `name`, y un `"default_project"` de nivel superior nombra el id al que caen las referencias simples, sin calificar.

```jsonc
"default_project": "p_1a2b3c4d",
"projects": {
  "p_1a2b3c4d": { "slug": "default", "name": "Default" },
  "p_5e6f7a8b": { "slug": "acme", "name": "Acme Inc", "default_model": "llm" }
},
"agents": {
  "assistant":    { "can_message": [] },          // proyecto por defecto
  "acme/sales":   { "can_message": ["acme/support"] },
  "acme/support": { "can_message": [] }
}
```

## Proyectos y canales

Un bot de Telegram vinculado a un agente de un proyecto mantiene toda la conversación dentro de ese proyecto. Un bot vinculado a un agente del proyecto por defecto atiende al proyecto por defecto, exactamente igual que antes de que añadieras un segundo proyecto.

## Topes de gasto y de mensajes

El proyecto es también la unidad que usa la facturación para medir el consumo. Cada llamada a un modelo se contabiliza por proyecto, y un proyecto puede llevar un tope mensual de gasto, un tope mensual de mensajes de clientes y un margen de facturación propio, incluido el proyecto por defecto. Consulta [Facturación y límites](../billing/) para definir, borrar y reiniciar esos topes, y [Agentes](../agents/) para ver qué campos del agente delimita el proyecto.
