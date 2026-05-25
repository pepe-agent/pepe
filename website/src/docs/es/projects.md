---
title: Proyectos
description: Aísla a un cliente de otro para que una sola instalación pueda atender a varios clientes sin que los datos de uno crucen jamás a los del otro.
---

## Qué es un proyecto

Un proyecto es un ámbito de cliente aislado. Una sola instalación puede atender a varios
clientes, y nada cruza de uno a otro: ni archivos, ni enrutamiento, ni claves de modelo.

Cada cliente es un proyecto, incluido el que obtienes de fábrica. Una instalación nueva
tiene un único **proyecto por defecto** (slug `default`), y ese es el proyecto que usa
cada comando cuando omites `--project`. El uso de un solo cliente no cambia: los nombres
de agente sin prefijo se resuelven dentro del proyecto por defecto, así que nunca tienes
que pensar en proyectos hasta que quieras un segundo cliente. Crea uno solo cuando tengas
que aislar de verdad a unos clientes de otros.

<div class="note"><strong>El proyecto por defecto es un proyecto normal.</strong> Aparece
en <code>project list</code> como cualquier otro, se puede renombrar, y lleva su propia
facturación. No existe un ámbito "root" especial con reglas distintas; omitir
<code>--project</code> simplemente recurre al proyecto por defecto.</div>

## El handle es la identidad

La identidad real de un agente es su **handle**. En el proyecto por defecto, el handle es
solo el nombre simple (`sales`). Dentro de otro proyecto se cualifica como `proyecto/nombre`
(`acme/sales`). El mismo nombre simple puede reutilizarse en cada proyecto, así que
`acme/sales` y `globex/sales` son dos agentes distintos.

El handle es lo que direcciona todo: el enrutamiento, las sesiones y los vínculos con los
canales lo usan. Por debajo, cada proyecto y cada agente lleva además un id interno estable,
y es ese id, no el nombre mutable, lo que registra el enrutamiento, los permisos, los
predeterminados y los vínculos de cron, bot y token. Renombrar un proyecto o un agente solo
cambia su etiqueta y mueve su directorio; cada referencia lo sigue, así que nada queda
colgando.

### Archivos

El workspace de un agente es `~/.pepe/projects/<slug>/agents/<nombre>/` y el espacio
compartido de su proyecto es `~/.pepe/projects/<slug>/shared/`. Los agentes con el mismo
nombre en proyectos distintos nunca escriben en el mismo directorio, y una ruta `shared/...`
nunca se filtra a otro cliente. El proyecto por defecto sigue la misma disposición bajo su
propio slug (`~/.pepe/projects/default/…`).

### Enrutamiento

`send_to_agent` nunca cruza la frontera de un proyecto. Un destino indicado con el nombre
simple se resuelve a un par dentro del propio proyecto de quien envía, y un bloqueo estricto
rechaza cualquier ruta entre proyectos, aunque una lista de permisos la pida.

### Modelos y claves

Un agente resuelve sus modelos primero dentro de su propio proyecto y solo después recurre al
proyecto por defecto. Así, un proyecto puede fijar claves de proveedor privadas que ningún
otro proyecto ve, o heredar un único proveedor global compartido. El agente o el modelo de un
proyecto nunca se promueve a predeterminado global, ni siquiera cuando es el primero que se
crea.

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
pepe project rename acme umbrella   # cambia su etiqueta y mueve su directorio;
                                    # todos los vínculos lo siguen, porque son por id
pepe project remove acme            # se niega mientras todavía tenga agentes
pepe project remove acme --force    # lo elimina, y se lleva sus agentes también
```

Como las referencias son por id, renombrar un proyecto (o un agente) nunca rompe una ruta, un
token, un cron ni un vínculo de bot. El nombre es una etiqueta; el id es lo que todo apunta.

## Cómo queda en la configuración

Los proyectos viven en un mapa `"projects"` indexado por un id estable, y cada entrada lleva
un `slug` y un `name`; un `"default_project"` de nivel superior nombra el id al que recurren
las referencias simples, sin cualificar.

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

Un bot de Telegram vinculado a un agente de un proyecto mantiene toda la conversación dentro
de ese proyecto. Un bot vinculado a un agente del proyecto por defecto atiende al proyecto por
defecto, exactamente igual que antes de que añadieras un segundo proyecto.

## Topes de gasto y de mensajes

El proyecto es además la unidad que mide la facturación. Cada llamada al modelo se mide por
proyecto, y un proyecto puede llevar un tope mensual de gasto, un tope mensual de mensajes de
clientes y un margen de facturación, incluido el proyecto por defecto. Consulta
[Facturación y límites](../billing/) para definirlos, borrarlos y reiniciarlos, y
[Agentes](../agents/) para los campos del agente que el proyecto delimita.
</content>
