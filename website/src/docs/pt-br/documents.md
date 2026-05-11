---
title: Documentos
description: Um arquivo enviado no chat chega como texto, lido na porta, junto com o que foi dito sobre ele.
---

## Um documento é uma mensagem, não uma pesquisa

Mande um PDF com a legenda "resume isso" e aquilo deveria ser lido como uma mensagem só. E é. O arquivo é lido quando chega, antes do roteamento, então o modelo recebe a instrução e o material juntos e responde sobre o conteúdo em vez de primeiro ter que ir atrás dele.

O agente *consegue* fazer isso sozinho, e até agora tinha que fazer: identificar o arquivo, escolher uma biblioteca, instalar, escrever um script, rodar. Funciona, e custa vários turnos, sai diferente a cada vez, e exige que o agente tenha `bash`, coisa que um agente que atende cliente nunca deve ter. Esse caminho continua existindo, como rede de segurança. Ele deixou de ser a porta de entrada.

## O que é lido, e quanto custa

| | |
|---|---|
| **Texto** (`.txt`, `.md`, `.csv`, `.json`, `.log`, `.xml` e afins) | Nada. É só ler o arquivo. |
| **`.docx`, `.xlsx`, `.pptx`** | Nada também. São arquivos ZIP com XML dentro, e o Erlang já descompacta. Sem Python, sem pacote de sistema, sem engordar a imagem. |
| **`.pdf`** | `pdftotext`, onde a máquina o tiver. Onde não tiver, o agente cai para se virar e instalar o que precisa, uma vez. |
| **Qualquer outra coisa** | Cai para o agente, que é o que acontecia com tudo antes. |

A planilha é o caso que merece explicação. Tirar as tags de um `.xlsx` produz algo que *parece* uma resposta: um monte das palavras que estavam lá, com os números sumidos e as linhas coladas umas nas outras. O Excel guarda os textos repetidos uma vez só, numa tabela compartilhada, e a célula guarda um **índice** para ela. Uma leitura ingênua entrega ao modelo uma lista de índices se passando por dados. Ele responderia com toda a confiança, errado, e ninguém saberia. Então as células são de fato lidas, e a planilha chega como linhas e colunas.

## Documentos longos

Só a primeira parte de um documento longo é entregue, para que um anexo não coma a janela de contexto. O arquivo inteiro fica no workspace do agente, e o agente é informado de onde, então quando precisar do resto ele lê o resto.

## Arquivos compactados não são abertos

Um `.zip` ou um `.tar.gz` é uma caixa, não um documento. Não existe "o texto" dele, e descompactar o que um estranho manda é aceitar uma bomba de descompressão e uma travessia de caminho no mesmo gesto. Ele cai para o agente, que o abre deliberadamente, com o portão de permissão na frente, e olha o que tem dentro antes de agir.

Os formatos do Office são seguros justamente porque **não** são genéricos: uma entrada é lida, pelo nome, na memória, e nada nunca é escrito em disco.

<div class="note"><strong>Mandar um é outra história.</strong> Pedir para o agente zipar uma pasta e te enviar funciona hoje: ele cria o arquivo com <code>bash</code> e entrega com <code>send_file</code>, no canal em que a conversa está. Criar o que você pediu não é a mesma coisa que abrir o que um estranho mandou.</div>
