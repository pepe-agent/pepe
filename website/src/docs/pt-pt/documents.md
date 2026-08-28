---
title: Documentos
description: Um ficheiro enviado numa conversa chega já como texto, lido à porta, junto com o que a pessoa disse sobre ele.
---

## Um documento é uma mensagem, não uma investigação

Envias um PDF com a legenda "resume isto" e o resultado devia parecer uma única mensagem. E parece: o ficheiro é lido assim que chega, antes de qualquer encaminhamento, de modo que o modelo recebe a instrução e o conteúdo ao mesmo tempo, e responde sobre esse conteúdo em vez de ter de o ir procurar primeiro.

O agente até *consegue* fazer isto sozinho, e até há pouco tempo era essa a única via: identificar o ficheiro, escolher uma biblioteca, instalá-la, escrever um script, correr o script. Funciona, mas custa vários turnos, sai diferente de cada vez, e obriga o agente a ter `bash`, coisa que um agente exposto a clientes nunca devia ter. Esse caminho continua disponível, como rede de segurança, mas deixou de ser a porta de entrada.

## O que se lê, e a que custo

| | |
|---|---|
| **Texto** (`.txt`, `.md`, `.csv`, `.json`, `.log`, `.xml` e afins) | Custo zero. O ficheiro é simplesmente lido. |
| **`.docx`, `.xlsx`, `.pptx`** | Também zero: o Pepe lê estes formatos por conta própria, sem instalar nada. |
| **`.pdf`** | `pdftotext`, quando a máquina o tem instalado. Onde não o tem, o agente desenrasca-se sozinho e instala o que precisa, uma única vez. |
| **Tudo o resto** | Cai para o agente, que é como funcionava tudo antes disto existir. |

Vale a pena explicar o caso da folha de cálculo. Tirar as etiquetas a um `.xlsx` produz uma coisa que *parece* uma resposta: um monte de palavras que lá estavam, sem os números e com as linhas todas coladas umas às outras. É que o Excel guarda o texto repetido uma única vez, numa tabela partilhada, e cada célula aponta para lá através de um índice. Uma leitura ingénua entrega ao modelo essa lista de índices a fazer-se passar por dados reais, e ele responderia com toda a confiança, e errado, sem que ninguém desse por isso. Por isso as células são lidas a sério, e a folha chega já organizada em linhas e colunas.

## Documentos longos

Só a primeira parte de um documento extenso é entregue de imediato, para que um único anexo não consuma a janela de contexto inteira. O ficheiro completo continua guardado no workspace do agente, que sabe onde o encontrar, e vai lá buscar o resto quando precisar dele.

## Arquivos comprimidos não se abrem sozinhos

Um `.zip` ou um `.tar.gz` é uma caixa, não um documento: não existe "o texto" desse ficheiro. E descomprimir automaticamente aquilo que um estranho envia é perigoso, porque um arquivo pode ser construído de propósito para encher o teu disco ao ser aberto, ou para deixar cair ficheiros fora da própria pasta. Por isso cai para o agente, que o abre de forma deliberada, com a barreira de permissão pela frente, e olha para o que lá está dentro antes de fazer seja o que for com isso.

Os formatos do Office são seguros precisamente por não serem genéricos: lê-se uma entrada, pelo nome, diretamente para memória, e nada chega alguma vez a ser escrito em disco.

<div class="note"><strong>Enviar um arquivo é outra conversa.</strong> Pedir ao agente para comprimir uma pasta e devolvê-la já funciona hoje: ele cria o arquivo com <code>bash</code> e entrega-o através de <code>send_file</code>, no mesmo canal onde a conversa está a decorrer. Criar aquilo que pediste não tem nada a ver com abrir aquilo que um estranho te mandou.</div>
