---
title: Documentos
description: Un archivo enviado en el chat llega como texto, leído en la puerta, junto con lo que se dijo sobre él.
---

## Un documento es un mensaje, no una investigación

Envía un PDF con el pie "resume esto" y eso debería leerse como un solo mensaje. Y así es. El archivo se lee cuando llega, antes del enrutamiento, así que el modelo recibe la instrucción y el material juntos y responde sobre el contenido en lugar de tener que ir primero a buscarlo.

El agente *puede* hacerlo por su cuenta, y hasta ahora tenía que hacerlo: identificar el archivo, elegir una biblioteca, instalarla, escribir un script, ejecutarlo. Funciona, y cuesta varios turnos, sale distinto cada vez, y exige que el agente tenga `bash`, algo que un agente que atiende a clientes nunca debe tener. Ese camino sigue existiendo, como red de seguridad. Ha dejado de ser la puerta de entrada.

## Qué se lee, y cuánto cuesta

| | |
|---|---|
| **Texto** (`.txt`, `.md`, `.csv`, `.json`, `.log`, `.xml` y similares) | Nada. Se lee el archivo. |
| **`.docx`, `.xlsx`, `.pptx`** | Tampoco nada. Son archivos ZIP con XML dentro, y Erlang ya descomprime. Sin Python, sin paquete de sistema, sin bytes en la imagen. |
| **`.pdf`** | `pdftotext`, donde la máquina lo tenga. Donde no, el agente vuelve a resolverlo por su cuenta e instala lo que necesita, una vez. |
| **Cualquier otra cosa** | Cae al agente, que es lo que pasaba antes con todo. |

La hoja de cálculo es el caso que merece explicación. Quitar las etiquetas de un `.xlsx` produce algo que *parece* una respuesta: un montón de las palabras que había, con los números desaparecidos y las filas pegadas unas a otras. Excel guarda los textos repetidos una sola vez, en una tabla compartida, y la celda guarda un **índice** hacia ella. Una lectura ingenua entrega al modelo una lista de índices haciéndose pasar por datos. Respondería con total confianza, mal, y nadie lo sabría. Por eso las celdas se leen de verdad, y la hoja llega como filas y columnas.

## Documentos largos

Solo se entrega la primera parte de un documento largo, para que un adjunto no se coma la ventana de contexto. El archivo entero se queda en el espacio de trabajo del agente, y al agente se le dice dónde, así que cuando necesita el resto, lee el resto.

## Los archivos comprimidos no se abren

Un `.zip` o un `.tar.gz` es una caja, no un documento. No existe "el texto" de una caja, y descomprimir lo que un desconocido te envía es aceptar una bomba de descompresión y un salto de ruta en el mismo gesto. Cae al agente, que lo abre deliberadamente, con la barrera de permisos por delante, y mira lo que hay dentro antes de actuar.

Los formatos de Office son seguros precisamente porque **no** son genéricos: se lee una entrada, por su nombre, en memoria, y nunca se escribe nada en disco.

<div class="note"><strong>Enviar uno es otra cosa.</strong> Pedirle al agente que comprima una carpeta y te la mande funciona hoy: crea el archivo con <code>bash</code> y lo entrega con <code>send_file</code>, en el canal en el que está la conversación. Crear lo que pediste no es lo mismo que abrir lo que un desconocido envió.</div>
