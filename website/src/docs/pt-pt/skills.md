---
title: Skills
description: Instala instruções reutilizáveis que ensinam fluxos repetíveis aos agentes.
---

Uma skill é um documento de instruções a pedido: um ficheiro Markdown que ensina
ao agente um *procedimento*, como instalar uma ferramenta ou lidar com uma
mensagem de áudio. É assim que um agente aprende algo novo sem que uma linha de
código mude.

## Listadas, não carregadas

Uma skill nunca é colada por inteiro no prompt do sistema. Só o nome e um resumo
de uma linha aparecem no contexto do agente. Quando o assunto surge, o agente
chama a ferramenta `skill` com esse nome, lê o documento completo e segue-o.

É precisamente essa indirecção que importa. O agente transporta dezenas de
procedimentos pagando apenas uma linha de contexto por cada um, e abre a versão
longa exactamente quando o trabalho o exige. O resumo é a primeira linha não
vazia do ficheiro, por isso essa linha de abertura deve dizer quando a skill se
aplica.

<div class="note"><strong>A ferramenta skill.</strong> O agente precisa da ferramenta <code>skill</code> na sua lista de ferramentas para ler skills. Sem ela, as skills ficam listadas no contexto mas nunca são abertas.</div>

## Skills nativas

Estas vêm com o Pepe, em `priv/skills/`:

- **`skill-creator`** - como criar, editar, auditar e melhorar skills (a meta-skill).
- **`install-tool`** - escrever uma ferramenta em plugin e activá-la pela conversa.
- **`write-a-script`** - resolver tarefas complexas escrevendo e guardando um programa para correr.
- **`manage-routing`** - alterar rotas entre agentes com `set_route`.
- **`handle-media`** - perceber uma entrada de voz, áudio, imagem ou ficheiro (transcrever, ler), instalando o que for preciso.
- **`install-skill`** - instalar uma skill a partir de um URL, um gist, um repositório ou outro Pepe.
- **`create-watch`** - criar um watch durável do tipo "verifica X e avisa-me quando acontecer".

## Escrever as tuas

As skills do utilizador ficam em `~/.pepe/skills/*.md`. Uma skill do utilizador
sobrepõe-se à nativa com o mesmo nome, por isso escreveres o teu próprio
`handle-media.md` substitui o que vem com o Pepe. A primeira linha não vazia é o
resumo; todo o resto é o procedimento, em Markdown simples, escrito para o
agente ler e seguir.

```bash
~/.pepe/skills/publicar-release.md
```

Não há passo de registo nem reinício. Basta colocares lá o ficheiro e a skill
aparece na lista do agente logo na mensagem seguinte.

### Deixa o agente escrevê-la

Um agente pode escrever as suas próprias skills. Pede-lhe que guarde como skill
a forma de fazer alguma coisa e, guiado pelo `skill-creator`, ele grava um novo
`skills/<nome>.md` que aparece de imediato na sua própria lista.

> Tu: resultou. guarda como skill o processo de publicar uma release
>
> Agente: guardei skills/publicar-release.md. Vou segui-lo da próxima vez que pedires uma release.

É isto que torna durável o conhecimento do agente. O procedimento que ele
descobriu uma vez fica escrito, em vez de ser redescoberto em cada sessão.

### Instalar uma vinda de fora

A skill `install-skill` ensina o agente a ir buscar uma skill a um URL, um gist,
um repositório ou outra instância do Pepe. Texto de skill vindo de fora é
entrada não fiável, por isso o agente analisa-o com a ferramenta `scan_skill`
antes de o gravar em disco. A análise sinaliza injecção de prompt, exfiltração
de segredos, comandos destrutivos, persistência e ofuscação. É uma segunda
verificação, e não um substituto para leres o conteúdo, e nunca instala nada por
si própria.

## Skills, plugins e scripts

Os três pontos de extensão compõem-se, e juntos são o que permite pedir a um
agente, em linguagem natural, algo que ele ainda não sabe fazer.

Combinado com [plugins](../plugins/) e o `enable_tool`, podes pedir pela conversa
que o agente instale uma ferramenta que faça X. Ele lê a skill `install-tool`,
escreve o plugin em `plugins/<nome>.exs`, activa a ferramenta em si mesmo e
começa a usá-la, sem reiniciar.

Para trabalho complexo ou de vários passos, o agente não faz tudo à mão. A
ferramenta `run_script` deixa-o escrever um programa curto (Python, Node, Ruby,
Bash ou Elixir, sendo que Elixir está sempre disponível) e executá-lo, recebendo
de volta stdout, stderr e o código de saída para iterar sobre os erros. Os
scripts que valem a pena são guardados em `scripts/` e reexecutados mais tarde,
passando ao `run_script` uma referência `file:`. Quando o agente descobre *como*
fazer uma tarefa recorrente, ler um PDF ou processar uma folha de cálculo,
escreve para si uma skill em `skills/<nome>.md`. A skill `write-a-script` ensina
todo esse ciclo.
