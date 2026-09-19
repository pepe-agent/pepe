---
title: Agentes
description: Define un agente a partir de un prompt, un modelo y un conjunto de herramientas, y deja que el runtime llame al modelo, ejecute herramientas y repita el ciclo hasta tener una respuesta.
---

## Qué es un agente

Un agente es una definición pequeña y declarativa: un nombre, un system prompt que
le da personalidad, una conexión de modelo con la que razonar, y una lista de
herramientas que puede llamar. Lo completan un puñado de ajustes extra (un límite
de iteraciones, una temperatura, con quién puede hablar, a quién puede administrar),
y eso es todo. El agente no contiene ninguna lógica propia; el runtime de Pepe hace
el trabajo entero: llama al modelo, ejecuta las herramientas que este pide, le
devuelve los resultados y repite hasta obtener una respuesta final.

Cada agente vive como una entrada dentro de un único archivo JSON en
`~/.pepe/config.json`. No hay base de datos. Hay tres formas de crear y editar
agentes, y las tres escriben en ese mismo archivo:

1. La herramienta de línea de comandos `pepe`.
2. El panel web.
3. Una conversación normal, hablando con un agente que tenga la herramienta de
   gestión correspondiente.

Así se ve un agente completo tal como queda guardado en disco:

```json
{
  "agents": {
    "assistant": {
      "description": "General-purpose helper",
      "model": "openrouter",
      "system_prompt": "Eres un asistente útil y directo.",
      "tools": ["bash", "read_file", "write_file", "web_search"],
      "auto_approve": [],
      "can_message": [],
      "can_manage": null,
      "hooks": [],
      "max_iterations": 12,
      "temperature": null
    }
  }
}
```

## Tu primer agente

Un agente necesita una conexión de modelo antes de poder razonar. Si todavía no
creaste ninguna, la configuración guiada te lleva de la mano para elegir un
proveedor, iniciar sesión y escoger un modelo:

```bash
pepe setup
```

Luego define un agente con un prompt y algunas herramientas:

```bash
pepe agent add assistant \
  --model openrouter \
  --prompt "Eres un asistente útil y directo." \
  --tools bash,read_file,write_file,web_search
```

Prueba un prompt de una sola vez. La respuesta se va transmitiendo a tu terminal a
medida que se genera:

```bash
pepe run assistant "¿Qué archivos hay en el directorio actual?"
```

Ese único comando dispara el ciclo completo: el agente decide que necesita mirar
el sistema de archivos, llama a la herramienta `list_dir` o `bash`, lee el
resultado y te contesta en lenguaje natural.

<div class="note"><strong>Desde el panel.</strong> La sección Agentes del panel web
hace lo mismo con un formulario: nombre, personalidad, modelo, una lista de
herramientas para marcar y el alcance de administración. El resultado es la misma
entrada escrita en <code>~/.pepe/config.json</code>, así que puedes combinar la CLI,
el panel y la edición manual sin ningún problema.</div>

### Hazlo por chat

Cualquier agente que tenga la herramienta `manage_agent` puede crear y configurar
otros agentes por conversación. Así es como el primerísimo agente (mira "El agente
propietario" más abajo) te deja armar el resto de tu flota sin tocar la CLI. Basta
con un mensaje como:

```text
Crea un agente llamado researcher. Dale una persona enfocada en investigación
web cuidadosa, apúntalo al modelo openrouter y activa web_search y
fetch_url.
```

El agente llama a `manage_agent` con `action: "create"`, y después a
`set_persona`, `set_model` y `add_tool` para cada capacidad. Como `manage_agent`
es una herramienta de riesgo, pasa por la barrera de permisos: en una superficie
que puede preguntar (la consola, un canal de chat) el runtime te pide autorizar el
cambio antes de escribirlo, y la propia herramienta trae la instrucción de
confirmar el plan contigo primero. Un agente solo puede gestionar los agentes
dentro de su alcance `can_manage` (más detalle en [Administrar agentes](#administrar-agentes)
un poco más abajo); si le pides que toque uno fuera de ese alcance, se niega
cortésmente.

## Los campos, uno por uno

| Campo | Qué hace | Valor por defecto |
|-------|--------------|---------|
| `name` | La etiqueta con la que se direcciona al agente. Dentro de un proyecto pasa a ser un handle como `acme/assistant` (mira más abajo). El agente también lleva un id interno estable, así que este nombre se puede cambiar sin romper ningún vínculo. | obligatorio |
| `description` | Una nota breve para humanos. Nunca se envía al modelo. | ninguna |
| `model` | El nombre de una conexión de modelo. Déjalo sin definir para que el agente use el modelo por defecto de su proyecto. | el del proyecto |
| `system_prompt` | La personalidad y las instrucciones con las que corre el agente. | `Eres Pepe, un agente de IA útil.` (un prompt semilla) |
| `langfuse_prompt` | Obtiene la persona desde el prompt con ese nombre en [Langfuse](#gestionar-una-persona-desde-langfuse), en vez de usar `system_prompt`. | `null` (desactivado) |
| `tools` | La lista de herramientas que este agente puede llamar. Solo esas se le ofrecen al modelo. | todas: un agente nuevo nace con todo habilitado, y quitas lo que no quieras |
| `auto_approve` | Herramientas que este agente puede ejecutar sin pedir permiso. `["*"]` significa todas. | `[]` |
| `can_message` | Otros agentes a los que este puede enviarles mensajes (una ruta dirigida). | `[]` |
| `can_manage` | Qué agentes puede administrar este. Mira [Administrar agentes](#administrar-agentes). | `null` (solo a sí mismo) |
| `hooks` | Transformaciones que se aplican al flujo de mensajes, como la censura de datos personales. | `[]` |
| `max_iterations` | El tope de cuántas rondas de modelo más herramienta puede tener un solo turno. | `12` |
| `temperature` | Temperatura de muestreo que se pasa al modelo. Sin definir, usa el valor por defecto del proveedor. | el del proveedor |
| `triage_model` | Una conexión de modelo que evalúa la complejidad antes del primer turno de una sesión. Mira [Enrutamiento de modelo por complejidad](#enrutamiento-de-modelo-por-complejidad). | ninguna (desactivado) |
| `simple_model` | La conexión de modelo a la que bajar cuando `triage_model` juzga simple una conversación. | ninguna |

## Cómo corre el ciclo de llamadas a herramientas

Cuando le mandas un mensaje a un agente, el runtime hace lo siguiente:

1. Llama al modelo con la conversación hasta ese punto y la descripción de cada
   herramienta que el agente tiene permitido usar.
2. Si el modelo responde con una contestación final, esa respuesta se devuelve y
   el ciclo termina ahí.
3. Si en cambio el modelo pide llamar a una o más herramientas, el runtime las
   ejecuta, agrega los resultados a la conversación y vuelve al paso 1.
4. Esto se repite hasta que el modelo entrega una respuesta final o el ciclo llega
   a `max_iterations`. Si se topa con ese límite, el turno termina con la nota
   `(stopped: max iterations reached)`.

Como los resultados vuelven a alimentar la conversación, el modelo puede encadenar
pasos: leer un archivo, decidir que necesita otro, leer ese también, y recién
entonces escribir un resumen, todo dentro del mismo turno. El límite de
iteraciones es justamente la salvaguarda que evita que un agente confundido dé
vueltas sin parar.

Antes de la llamada al modelo hay otras dos barreras. Un agente cuyo modelo exige
censura se niega a correr a menos que tenga activado un hook de censura, y un
proyecto que ya llegó a su tope de gasto mensual (o a su tope de mensajes de
clientes por mes, que es un límite aparte) se detiene aquí mismo, sin nuevas
llamadas al modelo ni respuestas. Las dos cosas hacen fallar el turno de forma
limpia en vez de dejarlo seguir en silencio; consulta Facturación y límites para
ver cómo se configuran esos topes.

<div class="note"><strong>Transmisión y eventos.</strong> Mientras corre, el ciclo
va emitiendo eventos de su ciclo de vida: un fragmento de texto en tránsito
(<code>assistant_delta</code>), un mensaje completo del asistente
(<code>assistant</code>), una llamada a herramienta (<code>tool_call</code>), una
herramienta rechazada (<code>tool_denied</code>), el resultado de una herramienta
(<code>tool_result</code>), un cambio a un modelo de respaldo
(<code>failover</code>), un registro de uso de tokens (<code>usage</code>), una
respuesta final (<code>done</code>) o un error (<code>error</code>). La CLI, el
WebSocket y los canales de mensajería muestran todo esto en vivo, por eso ves la
escritura y la actividad de herramientas ocurrir en tiempo real, en vez de recibir
un solo bloque al final.</div>

## Conversaciones largas: la compactación

Una conversación no crece sin límite dentro de la ventana de contexto del modelo.
Cuando el tamaño estimado supera más o menos el 60% de esa ventana, el runtime
reemplaza el **medio** del historial con un resumen breve que el propio modelo
redacta, y conserva palabra por palabra el system prompt y los turnos más
recientes. Esto es automático y no requiere ninguna configuración: la
transcripción completa se sigue guardando entera (consulta Traces), lo único que
se condensa es lo que se le envía al modelo.

Por defecto, ese resumen se genera **una sola vez** cada vez que se vuelve a
cruzar el umbral, empezando siempre de cero. Eso funciona bien para la mayoría de
las conversaciones, pero una que se extiende mucho puede tropezar con el umbral
una y otra vez, resumiendo cada vez un tramo del medio que no dejó de crecer. Como
alternativa, un agente puede activar `micro_compaction`: en cuanto la ventana se
llena, pliega en cada turno el intercambio más antiguo que todavía no forma parte
del resumen, así el costo es pequeño y constante en vez de una pausa periódica. La
contrapartida es real, y por eso viene desactivado por defecto: una vez activo, el
resumen cambia en cada turno, lo que le quita al proveedor la posibilidad de
reutilizar su copia en caché del inicio fijo del prompt entre una llamada y otra.
Vale la pena para una conversación que llega al umbral con frecuencia, no para una
corta.

```bash
pepe agent add support --micro-compaction ...
```

También puedes activarlo en un agente ya existente desde el editor de agentes del
panel, o pidiéndole a un agente con la herramienta `manage_agent` que active el
interruptor `micro_compaction` en otro agente.

## Mencionar qué más sabe hacer

Quien ya usa un agente para una sola cosa muchas veces nunca se entera de que ese
mismo agente también puede vigilar algo hasta que cambie, correr una tarea
recurrente o perseguir un objetivo hasta cumplirlo de verdad. Nada saca eso a la
luz, salvo lo que la propia persona del agente decida mencionar. `capability_nudge`,
que viene desactivado por defecto, deja que el agente agregue una frase corta y
natural señalando una funcionalidad relacionada justo después de ayudar con algo,
solo cuando de verdad encaja: no es un menú, y no aparece en cada turno. Es
descubrimiento a través del uso, no una avalancha de bienvenida.

```bash
pepe agent add support --capability-nudge ...
```

Déjalo desactivado en un agente que deba mantenerse breve y transaccional;
actívalo desde el editor de agentes del panel, o pidiéndole a un agente con la
herramienta `manage_agent` que active el interruptor `capability_nudge` en otro
agente.

## Aprender de lo que hace

Un agente que resuelve un procedimiento desde cero suele tirar ese hallazgo a la basura:
nadie se detiene a mitad de la tarea para pedir que quede guardado. `skill_learning`,
desactivado por defecto, deja que sea el propio agente quien lo plantee. Después de una
tarea que costó trabajo de verdad (al menos cuatro llamadas a herramientas con éxito, en
al menos dos herramientas, sin ninguna skill existente consultada) puede ofrecerse, en una
frase, a guardar ese camino como skill, para que la próxima vez vaya directo. Y cuando
sigue una skill que lo lleva por mal camino, puede ofrecerse a corregirla con lo que le
enseñó el fallo, como una edición a la que ya existe.

```bash
pepe agent add ops --skill-learning ...
```

La oferta es toda la funcionalidad: ningún archivo de skill se escribe ni se cambia sin un
sí explícito. A diferencia de `capability_nudge`, no cuesta nada en un turno normal,
porque no hay un párrafo extra en el prompt de sistema, solo una nota corta en los turnos
que cruzan el listón. Mira [Skills](../skills/) para lo que el agente escribe luego.

## Herramientas y la barrera de permisos

Una herramienta es una capacidad. Un agente solo puede hacer lo que su lista
`tools` le permite: dale `read_file` pero no `write_file` y podrá mirar, pero no
tocar.

Para ver todas las herramientas disponibles en tu instalación:

```bash
pepe tools
```

El conjunto integrado cubre lo esencial:

| Herramienta | Qué hace |
|------|--------------|
| `bash` | Ejecuta un comando de shell. |
| `run_script` | Escribe y ejecuta un programa corto en Python, Node, Ruby o Elixir. |
| `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir` | Trabaja con archivos dentro del espacio de trabajo del agente. |
| `fetch_url`, `web_search` | Lee una página web o busca en la web. |
| `send_file` | Entrega un archivo que el agente generó, por el canal actual. |
| `send_to_agent` | Envía un mensaje a otro agente (sujeto a `can_message`). |
| `ask_user` | Te pide elegir entre varias opciones, con botones o un menú reales donde el canal lo permite. |
| `schedule_task`, `watch` | Crea trabajos recurrentes y vigilancias puntuales del tipo "avísame cuando pase X". |
| `manage_agent`, `rename_agent`, `enable_tool`, `set_route` | Gestiona agentes, herramientas y enrutamiento desde el chat. |
| `manage_channel`, `end_session` | Conecta y cierra canales de mensajería desde el chat. |
| `manage_mcp`, `scan_skill`, `skill` | Agrega servidores de herramientas externas y skills. |
| `manage_plugin` | Instala, escanea, lista y elimina plugins de la comunidad (herramientas, canales) desde el chat. |
| `config_get`, `config_set`, `doctor` | Inspecciona y cambia la configuración con salvaguardas, y ejecuta diagnósticos. |

Algunas herramientas solo leen, así que corren sin restricciones: `read_file`,
`list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`,
`scan_skill` y `send_to_agent` (que en cambio se rige por las rutas permitidas en
`can_message`). Todo lo demás, incluida cualquier herramienta de un plugin, se
considera de riesgo y pasa por una barrera de permisos antes de ejecutarse.

Cuando una herramienta de riesgo todavía no fue aprobada de antemano y la
superficie puede preguntarle a una persona (la consola, un canal de chat), el
runtime te pide autorizar la llamada. Tus opciones son:

- Permitir una vez. La próxima vez vuelve a preguntar.
- Permitir por el resto de esta ejecución. Solo se ofrece mientras la ejecución
  haya recibido contenido de fuera (consulta [Seguridad y entorno aislado](../security/)):
  es el único tipo de preaprobación que de verdad sigue vigente durante esa ventana.
- Permitir por el resto de esta sesión. Queda en memoria y se olvida al reiniciar.
- Permitir siempre. Se guarda de forma persistente en el agente, agregando la
  herramienta a su lista `auto_approve`.
- Denegar. No se recuerda nunca, así que se vuelve a preguntar la próxima vez.

Puedes poner tú mismo una herramienta en `auto_approve` para saltarte el aviso
desde el principio. En superficies donde no hay ninguna persona a quien
preguntarle (por ejemplo la API HTTP, un webhook, una tarea de cron), una
herramienta con barrera se rechaza directamente en vez de ejecutarse sin
vigilancia: solo corre lo que ya está en `auto_approve`.

### Pedirte que elijas

Algunas preguntas se responden mejor con un toque que con una respuesta escrita.
`ask_user` deja que un agente presente una pregunta de opción múltiple genuina y
reciba la elección de vuelta dentro del mismo turno, en vez de adivinar o cerrar
su turno confiando en que el próximo mensaje conteste justo lo que preguntó.
Telegram la muestra como botones reales integrados en el chat; la consola, como
un menú numerado; el chat del panel, como opciones que se pueden pulsar. Corre sin
restricciones (preguntar no conlleva ningún riesgo propio, así que nunca pasa por
la barrera), pero solo funciona donde hay una persona interactiva del otro lado:
la API HTTP, un webhook o una ejecución desatendida de cron o watch rechazan la
llamada de entrada, en vez de quedarse esperando un botón que nadie va a pulsar.

### Hazlo por chat

Un agente que acaba de instalar un plugin, o que quiere una capacidad que todavía
no tiene, puede activarse a sí mismo una herramienta con `enable_tool`:

```text
Activa la herramienta web_search para ti mismo.
```

El agente llama a `enable_tool` con el nombre de la herramienta. Esta ya debe
existir, sea integrada o como plugin instalado, y el cambio surte efecto en el
siguiente mensaje del agente. `enable_tool` también pasa por la barrera de
permisos, así que autorizas la concesión antes de que quede escrita.

## La conexión de modelo

`model` nombra una conexión que definiste con `pepe model add`. Si lo dejas sin
definir, el agente usa el modelo por defecto de su proyecto, así que puedes
apuntar todo un grupo de agentes a un mismo proveedor y cambiarlos a todos
modificando un único valor por defecto.

Una conexión de modelo puede llevar una cadena de respaldo. Cuando el modelo
principal del agente falla con un error transitorio (un límite de tasa, un tiempo
de espera agotado, un corte de red, un 5xx), el runtime baja por la cadena y
reintenta con el siguiente modelo, emitiendo un evento `failover` al hacerlo. Un
error grave, como una clave de API inválida o una petición mal formada, falla de
inmediato en cambio, porque otro endpoint tampoco lo resolvería.

Pepe habla con los proveedores mediante el protocolo Chat Completions de OpenAI,
así que cualquier endpoint compatible con OpenAI funciona sin cambiar una sola
línea de código.

### Hazlo por chat

Un agente con la herramienta `manage_agent` puede reapuntar un modelo que
administra:

```text
Apunta al agente researcher hacia el modelo groq-fast.
```

El agente llama a `manage_agent` con `action: "set_model"`. El modelo de destino
tiene que ser una conexión ya configurada, y el cambio pasa por la barrera de
permisos igual que cualquier otra edición de configuración.

## Enrutamiento de modelo por complejidad

El propio `model` de un agente se trata como la buena opción por defecto. Como
alternativa, una primera evaluación rápida y barata puede decidir si una
conversación es lo bastante simple como para *bajar* a un modelo más económico,
antes incluso de que arranque el turno real. No hace falta configurar ningún
agente adicional, solo dos campos:

- `triage_model`: una conexión de modelo que clasifica el mensaje entrante con un
  prompt fijo e integrado, no una persona que tú escribas. Pepe simplemente busca
  la palabra "SIMPLE" en su respuesta.
- `simple_model`: la conexión de modelo a la que bajar (y en la que se queda, por
  el resto de la sesión) en cuanto el veredicto del triaje sea simple.

```bash
pepe agent add assistant \
  --model modelo-fuerte-y-caro \
  --triage-model modelo-barato-y-rapido \
  --simple-model modelo-de-uso-diario \
  --prompt "..." \
  --tools bash,read_file,web_search
```

El triaje corre una sola vez, en el primerísimo turno de una sesión, y nunca más
para esa misma sesión: en cuanto una conversación se juzga simple, se queda en el
modelo más económico por el resto de la charla (el mismo mecanismo que usa el
comando `/model` para cambiar el modelo de una sesión, solo que aquí se activa
automáticamente en vez de a mano). Un veredicto complejo no cambia nada: la
sesión corre con el modelo propio del agente, exactamente igual que si
`triage_model` nunca se hubiera definido.

El triaje es una optimización de mejor esfuerzo, jamás una dependencia. Si el
modelo de triaje no existe, no responde, o simplemente tarda demasiado (hay un
tope de pocos segundos), el turno sigue adelante con el modelo propio del agente,
sin hacer ruido; una caída del triaje nunca bloquea ni rompe una conversación.
`simple_model` también tiene que estar definido para que el triaje corra siquiera,
porque de lo contrario no habría a dónde bajar.

Cada veredicto queda registrado como un paso propio dentro del Trace de ese turno
(la reproducción de cada ejecución en el panel), junto con cualquier hook de
privacidad que se haya aplicado al mensaje, así que puedes ver con exactitud por
qué una sesión terminó en un modelo y no en el otro.

## El agente por defecto

Cada proyecto puede tener un agente marcado como el de por defecto: es el que se
ejecuta cuando no nombras a ninguno en particular.

```bash
pepe run "resume este repositorio"
```

El primer agente que creas en el proyecto por defecto se convierte
automáticamente en el agente por defecto. Puedes cambiarlo cuando quieras:

```bash
pepe agent default assistant
```

## El agente propietario

El primerísimo agente que se crea durante la configuración es el agente propio
del dueño de la instalación, y nace con todas las capacidades: recibe todas las
herramientas, es superadministrador sobre el resto de los agentes (`can_manage`
vale `["*"]`), y todas sus llamadas a herramientas están preaprobadas
(`auto_approve` vale `["*"]`), así que nunca se detiene a preguntar. Esto es lo
que te permite ponerte a trabajar de verdad por chat desde el primer minuto,
incluida la creación y configuración de todos los agentes que vengan después. Los
agentes que agregues más adelante nacen más acotados por defecto: tú eliges sus
herramientas, cada uno se administra solo a sí mismo, y sus llamadas de riesgo
pasan por la barrera de permisos.

## Dejar que los agentes se hablen entre sí

`can_message` es una lista de rutas permitidas, y es dirigida: si el agente A
incluye al agente B, entonces A puede mandarle un mensaje a B con la herramienta
`send_to_agent`. Lo contrario no se asume nunca. Agrega una ruta desde la CLI:

```bash
pepe agent route triage assistant
```

Ahora `triage` puede pasarle trabajo a `assistant`. Quita la ruta con `--remove`.
Las rutas nunca cruzan la frontera entre proyectos: la CLI rechaza un `A -> B`
cuando los dos agentes están en proyectos distintos.

### Hazlo por chat

Un agente con la herramienta `set_route` puede cambiar el enrutamiento por
conversación. `from` toma por defecto al agente que hace la llamada:

```text
Permítete enviarle mensajes al agente de facturación.
```

El agente llama a `set_route` con `action: "allow"` y `to: "billing"`. Como el
enrutamiento es dirigido, esto no hace que `billing` pueda responderle de vuelta.
Y como edita la configuración, `set_route` pasa por la barrera de permisos y eres
tú quien autoriza el cambio.

## Administrar agentes

`can_manage` controla qué agentes puede administrar un agente (crearlos,
editarlos, reconfigurarlos, entrenarlos) mediante la herramienta `manage_agent`.
Viene cerrado por defecto y su significado es exacto:

- Sin definir (`null`): el agente solo puede administrarse a sí mismo.
- Vacío (`[]`, definido con `--can-manage none`): no puede administrar a nadie, ni
  siquiera a sí mismo. Es un hijo bloqueado, por ejemplo un agente de cara al
  cliente que no debe poder alterarse a sí mismo.
- Una lista de nombres: exactamente esos agentes, y ningún otro. Incluye su
  propio nombre si además quieres que pueda administrarse a sí mismo.
- `["*"]` (definido con `--can-manage "*"`): todos los agentes. Un
  superadministrador explícito.

Para conceder autoridad de gestión directamente:

```bash
pepe agent manage supervisor "*"
```

### Hazlo por chat

Un agente administrador usa `manage_agent` para moldear a los agentes de su
alcance. Sus acciones son `list`, `get`, `create`, `set_persona`, `set_model`,
`add_tool`, `remove_tool` y `remember` (agrega un hecho duradero a la memoria del
destino). Por ejemplo:

```text
Dale al agente de soporte la herramienta send_file y registra en su memoria que
los reembolsos superiores a 200 necesitan una persona.
```

El agente llama a `manage_agent` con `action: "add_tool"` y después con
`action: "remember"`. Cada una de estas acciones pasa por la barrera de permisos:
el agente propone el cambio, tú lo autorizas, y solo entonces se aplica. Un
agente también puede renombrarse a sí mismo con la herramienta aparte
`rename_agent` ("De ahora en adelante, llámate scout"), que mueve su directorio
de espacio de trabajo y toma efecto en el siguiente mensaje.

## Agentes multi-cliente con proyectos

Cada agente vive dentro de un proyecto. En una instalación nueva ese es el único
**proyecto por defecto**, al que recurre cualquier comando cuando omites
`--project`, tal como siempre funcionó una instalación de un solo cliente. Agrega
un segundo proyecto para aislar a un cliente distinto: sus agentes, espacios de
trabajo, espacio compartido, conexiones de modelo y enrutamiento quedan separados
del resto de los proyectos.

La identidad real de un agente es su handle. En el proyecto por defecto ese handle
es simplemente el nombre a secas (`assistant`). Dentro de otro proyecto se
cualifica como `proyecto/nombre` (`acme/assistant`), de modo que el mismo nombre
puede repetirse en distintos proyectos sin chocar entre sí.

Crea un proyecto y luego agrega agentes dentro de él con `--project`:

```bash
pepe project add acme --description "Acme Corp"

pepe agent add support \
  --project acme \
  --model openrouter \
  --prompt "Eres el agente de soporte de Acme." \
  --tools read_file,web_search
```

Agrega `--project acme` a cualquier comando de agente para operar dentro de ese
alcance. Los nombres de pares a secas en `--can-message` y `--can-manage` se
resuelven dentro del propio proyecto del agente, así que las rutas nunca cruzan
por accidente la frontera de un cliente. Cada proyecto puede fijar su propio
modelo y agente por defecto, o compartir el proveedor global del operador. Un
agente creado dentro de un proyecto que no es el por defecto jamás se convierte
en el predeterminado global solo por haber sido el primero en ese proyecto.

Tanto los proyectos como los agentes llevan un id interno estable, y cada vínculo
(enrutamiento, autoridad de gestión, valores por defecto, crons, bots, tokens)
queda registrado contra ese id, no contra el nombre. Renombrar un proyecto o un
agente solo cambia su etiqueta y mueve su directorio; nada de lo que apuntaba a
él queda roto.

## Gestionar agentes desde la CLI

```bash
# Crea un agente. Omite --tools para conceder todas las herramientas; pasa --tools "" para ninguna.
pepe agent add NAME \
  --model MODEL \
  --prompt "..." \
  --tools t1,t2 \
  [--description "..."] \
  [--can-message b,c] \
  [--can-manage x,y | "*" | none] \
  [--hooks pii_redact] \
  [--max-iterations 12] \
  [--temperature 0.7] \
  [--triage-model MODEL] \
  [--simple-model MODEL] \
  [--default] \
  [--project PROJECT]

# Lista los agentes de un proyecto, o todos los agentes en general.
pepe agent list [--project PROJECT | --all]

# Imprime el system prompt completo ya ensamblado, no solo el campo de persona,
# sino todo lo que Pepe construye alrededor. Ver "Ver exactamente lo que ve el
# modelo" más abajo.
pepe agent prompt NAME [--project PROJECT]

# Mensajería dirigida: deja que FROM le envíe mensajes a TO.
pepe agent route FROM TO [--remove] [--project PROJECT]

# Autoridad de gestión: deja que ADMIN administre a TARGET (o "*" para todos).
pepe agent manage ADMIN TARGET [--remove] [--project PROJECT]

# Renombra un agente y mueve su directorio de espacio de trabajo.
pepe agent rename OLD NEW

# Elimina un agente.
pepe agent remove NAME [--project PROJECT]

# Define el agente por defecto de un proyecto.
pepe agent default NAME [--project PROJECT]
```

## Ejecutar un agente

Al mismo agente se llega de cuatro formas distintas.

**De una sola vez, desde la CLI.** Sin sesión, transmite directo a stdout.

```bash
pepe run assistant "tu prompt aquí"
```

**Consola interactiva.** Mantiene la conversación, así que el contexto se
traslada de un turno a otro. Reanuda o separa sesiones de consola con
`--session KEY`.

```bash
pepe chat assistant
```

**Por HTTP y WebSocket.** Arranca el servidor y luego llama a la API compatible
con OpenAI, o abre un WebSocket con transmisión en vivo. El campo `model` de la
petición es el que nombra al agente.

```bash
pepe serve --port 4000
```

```http
POST /v1/chat/completions
Content-Type: application/json

{
  "model": "assistant",
  "messages": [{ "role": "user", "content": "tu prompt aquí" }]
}
```

El WebSocket se sirve en `ws://localhost:4000/socket/websocket`, y la
comprobación de estado en `GET /health`.

**Por un canal de mensajería.** Vincula un agente a una conexión de Telegram,
WhatsApp, Slack, Discord, Microsoft Teams o Google Chat, o a un webhook entrante
genérico, y ahí responde con el mismo ciclo y las mismas herramientas.

## Gestionar una persona desde Langfuse

Define `langfuse_prompt` con el nombre de un prompt y la persona de este agente
pasa a venir de [Langfuse](../langfuse/) en vez de su propio `system_prompt` o
`SOUL.md`: edita el prompt en Langfuse y el cambio llega a Pepe en cuestión de
minutos, sin necesidad de redeploy ni de tocar `config.json`.

```bash
pepe agent add support --langfuse-prompt support-persona
```

Es una opción por agente: uno que no tenga `langfuse_prompt` definido queda
completamente sin cambios, y si la obtención falla (el servicio no responde, el
nombre no existe), el agente cae directo a su persona local. Encontrarás la
configuración y las credenciales en [Langfuse](../langfuse/).

## Ver exactamente lo que ve el modelo

El campo `system_prompt` es apenas la semilla. Lo que de verdad le llega al
modelo como mensaje de sistema incluye además los archivos de persona, identidad
o arranque del agente, si los tiene, un contrato de comportamiento breve, la hora
actual y un índice de los docs y skills que conoce, nada de lo cual aparece si
solo lees el campo tal como está en disco. Para ver todo eso ensamblado, exactamente
como lo mandaría una conversación real:

```bash
pepe agent prompt NAME
```

La página de edición del agente en el panel tiene la misma vista, bajo
**Prompt ensamblado**, contraída por defecto porque puede ser bastante larga.
