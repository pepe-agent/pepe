---
title: Documentos
description: Um ficheiro enviado no chat chega como texto, lido à porta, junto com o que foi dito sobre ele.
---

## Um documento é uma mensagem, não uma investigação

Envie um PDF com a legenda "resume isto" e aquilo devia ler-se como uma única mensagem. E lê-se. O ficheiro é lido quando chega, antes do encaminhamento, por isso o modelo recebe a instrução e o material juntos e responde sobre o conteúdo em vez de ter primeiro de ir à procura dele.

O agente *consegue* fazê-lo sozinho, e até agora tinha de o fazer: identificar o ficheiro, escolher uma biblioteca, instalá-la, escrever um script, executá-lo. Funciona, e custa vários turnos, sai diferente de cada vez, e exige que o agente tenha `bash`, coisa que um agente que atende clientes nunca deve ter. Esse caminho continua a existir, como rede de segurança. Deixou de ser a porta de entrada.

## O que é lido, e quanto custa

| | |
|---|---|
| **Texto** (`.txt`, `.md`, `.csv`, `.json`, `.log`, `.xml` e afins) | Nada. Lê-se o ficheiro. |
| **`.docx`, `.xlsx`, `.pptx`** | Também nada. São arquivos ZIP com XML lá dentro, e o Erlang já descomprime. Sem Python, sem pacote de sistema, sem bytes na imagem. |
| **`.pdf`** | `pdftotext`, onde a máquina o tenha. Onde não tenha, o agente volta a desenrascar-se e instala o que precisa, uma vez. |
| **Qualquer outra coisa** | Cai para o agente, que é o que acontecia com tudo antes. |

A folha de cálculo é o caso que merece explicação. Retirar as etiquetas de um `.xlsx` produz algo que *parece* uma resposta: um monte das palavras que lá estavam, com os números desaparecidos e as linhas coladas umas às outras. O Excel guarda os textos repetidos uma só vez, numa tabela partilhada, e a célula guarda um **índice** para ela. Uma leitura ingénua entrega ao modelo uma lista de índices a fazer-se passar por dados. Ele responderia com toda a confiança, errado, e ninguém saberia. Por isso as células são realmente lidas, e a folha chega como linhas e colunas.

## Documentos longos

Só a primeira parte de um documento longo é entregue, para que um anexo não coma a janela de contexto. O ficheiro inteiro fica no espaço de trabalho do agente, e o agente é informado de onde, por isso quando precisar do resto lê o resto.

## Arquivos comprimidos não são abertos

Um `.zip` ou um `.tar.gz` é uma caixa, não um documento. Não existe "o texto" dele, e descomprimir o que um estranho envia é aceitar uma bomba de descompressão e uma travessia de caminho no mesmo gesto. Cai para o agente, que o abre deliberadamente, com a barreira de permissão pela frente, e olha para o que lá está antes de agir.

Os formatos do Office são seguros precisamente porque **não** são genéricos: uma entrada é lida, pelo nome, para memória, e nada é alguma vez escrito em disco.

<div class="note"><strong>Enviar um é outra história.</strong> Pedir ao agente para comprimir uma pasta e enviá-la funciona hoje: cria o arquivo com <code>bash</code> e entrega-o com <code>send_file</code>, no canal em que a conversa está. Criar o que pediu não é o mesmo que abrir o que um estranho enviou.</div>
