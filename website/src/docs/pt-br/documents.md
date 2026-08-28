---
title: Documentos
description: Um arquivo enviado no chat chega como texto, já lido na porta, junto com o que foi dito sobre ele.
---

## Um documento é uma mensagem, não uma tarefa de pesquisa

Alguém manda um PDF com a legenda "resume isso", e é assim mesmo que deveria funcionar: como uma mensagem só. E funciona. O arquivo é lido assim que chega, antes até do roteamento, então o modelo recebe junto a instrução e o material, e já responde sobre o conteúdo em vez de primeiro precisar ir atrás dele.

O agente até *consegue* fazer isso sozinho, e até pouco tempo atrás era obrigado: identificar o arquivo, escolher uma biblioteca, instalar, escrever um script, rodar. Funciona, só que consome vários turnos, sai diferente a cada vez, e exige que o agente tenha `bash` à disposição, coisa que um agente na linha de frente com clientes nunca deveria ter. Esse caminho continua existindo como rede de segurança. Só deixou de ser a porta de entrada.

## O que é lido, e o que isso custa

| | |
|---|---|
| **Texto** (`.txt`, `.md`, `.csv`, `.json`, `.log`, `.xml` e parecidos) | Nada. É só ler o arquivo. |
| **`.docx`, `.xlsx`, `.pptx`** | Também nada. O Pepe lê esses formatos sozinho, sem precisar instalar nada a mais. |
| **`.pdf`** | `pdftotext`, quando a máquina já o tem. Quando não tem, o agente se vira e instala o que precisa, uma vez só. |
| **Qualquer outra coisa** | Cai para o agente resolver, do jeito que acontecia com tudo antes. |

A planilha é o caso que merece uma explicação à parte. Tirar as tags de um `.xlsx` na marra produz algo que até *parece* uma resposta: um amontoado das palavras que estavam lá, com os números sumidos e as linhas grudadas umas nas outras. É que o Excel guarda os textos repetidos uma única vez, numa tabela compartilhada, e cada célula guarda apenas um índice para essa tabela. Uma leitura ingênua entrega ao modelo uma lista de índices se passando por dado de verdade, e ele responderia com toda a confiança, errado, sem que ninguém percebesse. Por isso as células são de fato lidas, e a planilha chega inteira, em linhas e colunas.

## Documentos longos

Só o começo de um documento longo é entregue de uma vez, para que um único anexo não devore a janela de contexto inteira. O arquivo completo continua salvo no workspace do agente, e ele sabe onde procurar, então basta ler o resto quando precisar do resto.

## Arquivo compactado não é aberto sozinho

Um `.zip`, um `.tar.gz`, é uma caixa, não um documento. Não existe "o texto" desse tipo de arquivo, e descompactar de cara qualquer coisa que um estranho manda é perigoso: dá para montar um arquivo desses de propósito, seja para lotar seu disco ao ser aberto, seja para jogar arquivos fora da própria pasta. Por isso ele cai para o agente, que abre deliberadamente, passando pelo portão de permissão, e só então olha o que tem lá dentro antes de fazer qualquer coisa com o conteúdo.

Os formatos do Office são seguros justamente por **não** serem genéricos: uma entrada é lida pelo nome, direto na memória, sem nada ser gravado em disco em nenhum momento.

<div class="note"><strong>Mandar um arquivo é outra história.</strong> Pedir para o agente compactar uma pasta e te devolver funciona hoje sem problema: ele monta o arquivo com <code>bash</code> e entrega pelo <code>send_file</code>, no mesmo canal em que a conversa está rolando. Criar o que você pediu não é o mesmo que abrir o que um estranho te mandou.</div>
