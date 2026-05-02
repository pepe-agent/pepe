---
title: Skills
description: Instale instruções reutilizáveis que ensinam fluxos repetíveis aos agentes.
---

Uma skill é um documento de instruções sob demanda: um arquivo Markdown que
ensina ao agente um *procedimento*, como instalar uma ferramenta ou lidar com
uma mensagem de áudio. É assim que um agente aprende algo novo sem que uma linha
de código mude.

## Listadas, não carregadas

Uma skill nunca é colada por inteiro no prompt do sistema. Só o nome e um resumo
de uma linha aparecem no contexto do agente. Quando o assunto surge, o agente
chama a ferramenta `skill` com esse nome, lê o documento completo e o segue.

É justamente essa indireção que importa. O agente carrega dezenas de
procedimentos pagando apenas uma linha de contexto por cada um, e abre a versão
longa exatamente quando o trabalho pede. O resumo é a primeira linha não vazia
do arquivo, então essa linha de abertura deve dizer quando a skill se aplica.

<div class="note"><strong>A ferramenta skill.</strong> O agente precisa da ferramenta <code>skill</code> na sua lista de ferramentas para ler skills. Sem ela, as skills ficam listadas no contexto mas nunca são abertas.</div>

## Skills nativas

Estas já vêm com o Pepe, em `priv/skills/`:

- **`skill-creator`** - como criar, editar, auditar e melhorar skills (a meta-skill).
- **`install-tool`** - escrever uma ferramenta em plugin e habilitá-la pela conversa.
- **`write-a-script`** - resolver tarefas complexas escrevendo e salvando um programa para rodar.
- **`manage-routing`** - alterar rotas entre agentes com `set_route`.
- **`handle-media`** - entender uma entrada de voz, áudio, imagem ou arquivo (transcrever, ler), instalando o que for preciso.
- **`install-skill`** - instalar uma skill a partir de uma URL, um gist, um repositório ou outro Pepe.
- **`create-watch`** - criar um watch durável do tipo "verifique X e me avise quando acontecer".

## Escrevendo as suas

As skills do usuário ficam em `~/.pepe/skills/*.md`. Uma skill do usuário
sobrepõe a nativa de mesmo nome, então escrever o seu próprio `handle-media.md`
substitui a que vem com o Pepe. A primeira linha não vazia é o resumo; todo o
resto é o procedimento, em Markdown puro, escrito para o agente ler e seguir.

```bash
~/.pepe/skills/publicar-release.md
```

Não há passo de registro nem reinício. Basta colocar o arquivo lá e a skill
aparece na lista do agente já na mensagem seguinte.

### Deixe o agente escrever

Um agente pode escrever as próprias skills. Peça que ele guarde como skill o
jeito de fazer alguma coisa e, guiado pelo `skill-creator`, ele grava um novo
`skills/<nome>.md` que já aparece na sua própria lista.

> Você: funcionou. guarde como skill o processo de publicar uma release
>
> Agente: salvei skills/publicar-release.md. Vou segui-lo na próxima vez que você pedir uma release.

É isso que torna durável o conhecimento do agente. O procedimento que ele
descobriu uma vez fica escrito, em vez de ser redescoberto a cada sessão.

### Instalando uma de fora

A skill `install-skill` ensina o agente a buscar uma skill em uma URL, um gist,
um repositório ou outra instância do Pepe. Texto de skill vindo de fora é
entrada não confiável, então o agente o escaneia com a ferramenta `scan_skill`
antes de gravá-lo em disco. A varredura sinaliza injeção de prompt, exfiltração
de segredos, comandos destrutivos, persistência e ofuscação. Ela é uma segunda
checagem, e não um substituto para ler o conteúdo, e nunca instala nada por
conta própria.

## Skills, plugins e scripts

Os três pontos de extensão se compõem, e juntos são o que permite pedir a um
agente, em linguagem natural, algo que ele ainda não sabe fazer.

Combinado com [plugins](../plugins/) e o `enable_tool`, dá para pedir pela
conversa que o agente instale uma ferramenta que faça X. Ele lê a skill
`install-tool`, escreve o plugin em `plugins/<nome>.exs`, habilita a ferramenta
em si mesmo e passa a usá-la, sem reiniciar.

Para trabalho complexo ou de várias etapas, o agente não faz tudo na mão. A
ferramenta `run_script` deixa que ele escreva um programa curto (Python, Node,
Ruby, Bash ou Elixir, sendo que Elixir está sempre disponível) e o execute,
recebendo de volta stdout, stderr e o código de saída para iterar sobre os
erros. Os scripts que valem a pena são salvos em `scripts/` e reexecutados
depois, passando ao `run_script` uma referência `file:`. Quando o agente
descobre *como* fazer uma tarefa recorrente, ler um PDF ou processar uma
planilha, ele escreve para si uma skill em `skills/<nome>.md`. A skill
`write-a-script` ensina todo esse ciclo.
