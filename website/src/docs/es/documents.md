---
title: Documentos
description: Un archivo enviado por chat se convierte en texto ya en la puerta de entrada, junto con lo que se dijo sobre él.
---

## Un documento es un mensaje, no una tarea de investigación

Manda un PDF con el pie de foto "resume esto" y eso debería contar como un
único mensaje. Y así es: el archivo se lee en el momento en que llega, antes
de enrutarse, de modo que el modelo recibe junta la instrucción con el
material y responde directamente sobre el contenido, sin tener que salir a
buscarlo primero.

El agente *puede* encargarse de esto por su cuenta, y hasta ahora no le
quedaba otra: identificar el archivo, elegir una biblioteca, instalarla,
escribir un script y ejecutarlo. Funciona, sí, pero cuesta varios turnos, el
resultado varía cada vez, y exige que el agente tenga `bash`, algo que un
agente de cara al cliente jamás debería tener. Ese camino sigue ahí, como red
de seguridad, pero ya dejó de ser la puerta principal.

## Qué se lee y qué cuesta

| | |
|---|---|
| **Texto** (`.txt`, `.md`, `.csv`, `.json`, `.log`, `.xml` y similares) | Nada. Se lee el archivo. |
| **`.docx`, `.xlsx`, `.pptx`** | Tampoco nada. Pepe lee estos formatos por su cuenta, sin nada extra que instalar. |
| **`.pdf`** | `pdftotext`, donde la máquina lo tenga. Donde no, el agente vuelve a resolverlo por su cuenta e instala lo que necesita, una vez. |
| **Cualquier otra cosa** | Cae al agente, que es lo que pasaba antes con todo. |

El caso que merece explicarse es el de las hojas de cálculo. Si simplemente
le quitas las etiquetas a un `.xlsx`, obtienes algo que *parece* una
respuesta, pero en realidad es un amasijo de palabras sueltas, sin los
números y con las filas mezcladas entre sí. Esto pasa porque Excel guarda
cada texto repetido una sola vez, en una tabla compartida, y cada celda solo
apunta a un índice dentro de ella. Una lectura ingenua le entregaría al
modelo esa lista de índices disfrazada de datos, y el modelo respondería con
total seguridad, pero mal, sin que nadie se diera cuenta. Por eso las celdas
se leen de verdad, y la hoja llega ya convertida en filas y columnas.

## Documentos largos

De un documento largo solo se entrega la primera parte, para que un único
adjunto no se devore toda la ventana de contexto. El archivo completo se
queda guardado en el workspace del agente, que sabe exactamente dónde
encontrarlo, así que si necesita el resto, simplemente lo lee.

## Los archivos comprimidos no se abren

Un `.zip` o un `.tar.gz` es una caja, no un documento: no existe "el texto"
de una caja. Además, descomprimir automáticamente cualquier cosa que te mande
un desconocido es peligroso, porque un archivo comprimido puede estar
diseñado para llenarte el disco al abrirse o para colocar archivos fuera de
su propia carpeta. Por eso esto cae en manos del agente, que lo abre de forma
deliberada, pasando por la barrera de permisos, y revisa el contenido antes
de hacer nada con él.

Los formatos de oficina son seguros justamente porque **no** son de
propósito general: se lee una sola entrada, identificada por su nombre,
directo a memoria, y nunca se escribe nada a disco.

<div class="note"><strong>Enviar un comprimido es harina de otro costal.</strong> Pedirle al agente que comprima una carpeta y te la devuelva ya funciona hoy: arma el archivo con <code>bash</code> y lo entrega con <code>send_file</code>, por el mismo canal donde está la conversación. Crear algo que tú pediste no tiene nada que ver con abrir algo que envió un desconocido.</div>
