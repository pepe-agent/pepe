---
title: Skills
description: Instruções reutilizáveis, instaláveis, que ensinam fluxos de trabalho repetíveis aos agentes.
---

Uma skill é um documento de instruções que só se abre quando é preciso: um ficheiro
Markdown que ensina ao agente um *procedimento*, seja como instalar uma ferramenta ou
como lidar com uma mensagem de áudio. É assim que um agente aprende algo novo sem que
uma única linha de código mude.

## Aparecem na lista, mas não carregam sozinhas

Uma skill nunca é colada por inteiro no prompt de sistema; no contexto do agente
aparecem só o nome e um resumo de uma linha. Quando o assunto surge, é o próprio
agente quem chama a ferramenta `skill` com esse nome, lê o documento inteiro, e
segue-o.

É essa indireção que mantém tudo barato. Um agente consegue carregar dezenas de
procedimentos pagando apenas uma linha de contexto por cada um, e só abre a versão
longa no exato momento em que o trabalho o exige. O resumo é simplesmente a primeira
linha não vazia do ficheiro, por isso vale a pena escrever essa abertura já a dizer
quando a skill se aplica.

<div class="note"><strong>A ferramenta skill.</strong> Sem a ferramenta <code>skill</code> na sua lista, o agente até vê as skills listadas no contexto, mas nunca chega a abri-las.</div>

## Skills nativas

Vêm de fábrica com o Pepe, em `priv/skills/`:

- **`skill-creator`**: como criar, editar, auditar e melhorar skills (a meta-skill).
- **`install-tool`**: escrever uma ferramenta em forma de plugin e ativá-la pela conversa.
- **`write-a-script`**: resolver tarefas complexas escrevendo e guardando um programa para correr.
- **`manage-routing`**: alterar rotas entre agentes através do `set_route`.
- **`handle-media`**: perceber uma entrada de voz, áudio, imagem ou ficheiro (transcrever, ler), instalando o que fizer falta.
- **`install-skill`**: instalar uma skill a partir de um URL, um gist, um repositório, ou outro Pepe.
- **`create-watch`**: montar um watch durável do género "verifica X e avisa-me quando acontecer".

## Escrever as tuas próprias

As skills do utilizador vivem em `~/.pepe/skills/*.md`. Uma skill do utilizador
sobrepõe-se sempre a uma nativa do mesmo nome, por isso, se escreveres o teu próprio
`handle-media.md`, é ele que passa a valer em vez do que vem com o Pepe. A primeira
linha não vazia funciona como resumo; tudo o resto é o procedimento em si, escrito em
Markdown simples, pensado para o agente ler e seguir.

```bash
~/.pepe/skills/publicar-release.md
```

Não há passo de registo, nem reinício: basta pousares o ficheiro ali e a skill já
aparece na lista do agente na mensagem seguinte.

### Deixa o próprio agente escrevê-la

Um agente consegue escrever as suas próprias skills. Pede-lhe que guarde como skill a
maneira de fazer alguma coisa e, guiado pelo `skill-creator`, ele grava um
`skills/<nome>.md` novo, que já aparece de imediato na sua própria lista.

> Tu: resultou. guarda como skill o processo de publicar uma release
>
> Agente: guardei skills/publicar-release.md. Vou segui-lo da próxima vez que pedires uma release.

É isto que torna durável o conhecimento acumulado por um agente: um procedimento
descoberto uma vez fica escrito, em vez de precisar de ser reinventado a cada sessão.

### Empacotar uma skill com scripts

Uma skill também pode chegar como um pequeno pacote em vez de um ficheiro solto: uma
pasta `<nome>/` com um `SKILL.md` (o documento de entrada, lido exatamente como um
`<nome>.md` avulso) ao lado do que mais for preciso, tipicamente uma pasta `scripts/`.

```bash
~/.pepe/skills/publicar-release/
  SKILL.md
  scripts/marcar-e-publicar.sh
```

Os ficheiros do pacote nunca são copiados para outro lado: o agente chega até eles
mesmo onde estão, do mesmo modo que já chega ao workspace partilhado ou a um plugin
instalado, passando ao `run_script` (ou ao `read_file`) um caminho no formato
`skills/<nome>/scripts/<ficheiro>`. Aponta as instruções do próprio `SKILL.md` para
esse caminho, e o script corre exatamente como foi empacotado, sem o agente ter de o
reescrever do zero a cada primeiro pedido de cada sessão.

Uma skill instalada pelo `manage_skill` ou pelo `mix pepe skill install` (mais abaixo)
traz o pacote inteiro com ela sempre que a fonte tiver um: basta um `SKILL.md` na raiz
do que foi instalado para marcar isso como pacote; qualquer coisa sem ele continua a
instalar-se como um único `<nome>.md`, exatamente como antes. E não é só o documento
que passa por análise de segurança antes de instalar, é cada ficheiro do pacote:
o `SKILL.md` recebe a análise habitual contra injeção de prompt, e cada script
incluído recebe a mesma análise profunda que o código de um plugin recebe.

### Instalar uma vinda de fora

Há dois caminhos, consoante a origem. Um agente com a ferramenta `manage_skill`
usa-a para tudo o que o marketplace conseguir resolver: um nome no registo incluído
ou num tap, ou uma referência do [PepeHub](https://hub.pepe-agent.com) (`@handle/nome`,
ou o próprio URL da página), a mesma instalação com conhecimento de registo que o `mix
pepe skill install` faz, com confiança e proveniência registadas da mesma forma. Para
uma fonte sem entrada em nenhum registo (um URL avulso, um gist, um repositório fora
de qualquer catálogo), é a skill `install-skill` que ensina o agente a ir buscá-la à
mão. Seja qual for o caminho, texto de skill vindo de fora é sempre entrada não
fiável: o agente analisa-o com a ferramenta `scan_skill` antes de o gravar em disco. A
análise sinaliza injeção de prompt, exfiltração de segredos, comandos destrutivos,
persistência e ofuscação, e serve como segunda verificação, não como substituto para
leres o conteúdo tu mesmo; nunca instala nada por conta própria.

## Instalar a partir de um marketplace

O `manage_skill` (visto acima) é o caminho conversacional para tudo o que os registos
ou o PepeHub conseguirem resolver. Já o `mix pepe skill` é o caminho do operador para
os mesmos registos, com a mesma pesquisa e a mesma história de atualização:

```bash
pepe skill search release            # pesquisa em cada tap mais o registo incluído
pepe skill install cut-a-release     # instala pelo nome
pepe skill install @jhonathas/google-workspace   # ou uma referência do PepeHub (vê abaixo)
pepe skill install cut-a-release --source https://example.com/cut-a-release.md   # ou diretamente
pepe skill update cut-a-release      # volta a obtê-la a partir da fonte exata de onde foi instalada
pepe skill tap add https://github.com/a-tua-equipa/pepe-skills   # acrescenta um registo além do incluído
```

Um nome no formato `@handle/nome` (ou o próprio URL da página do pacote, copiado
diretamente do [PepeHub](https://hub.pepe-agent.com)) resolve-se contra o PepeHub em
si, o registo de plugins e skills do Pepe, em vez do registo incluído ou de um tap; é
verificado primeiro, já que nenhuma entrada incluída ou de tap usa esse formato. Fica
instalado sob o slug puro do pacote (`google-workspace`, e não
`@jhonathas/google-workspace`), o nome que todos os outros comandos de skill e a
própria ferramenta `skill` usam. Se apontares o `skill install` para um nome que
afinal é um plugin no PepeHub, e não uma skill, a instalação falha com uma mensagem
clara a indicar `plugin install` em vez disso.

Toda instalação passa pela mesma análise de segurança estática que o
`manage_skill`/`install-skill` já usam; um veredito perigoso é recusado a menos que
passes `--force`. A confiança fica marcada como `"official"` para o registo incluído
no próprio repositório (curado pela equipa que mantém o Pepe) e para um pacote do
PepeHub que o próprio PepeHub marcou manualmente como oficial. Tudo o resto, resolvido
através de um tap que tu adicionaste, um pacote do PepeHub sem essa marca, ou instalado
com `--source`, fica marcado como `"community"`: quando um agente o lê pela ferramenta
`skill`, o conteúdo vem envolvido no mesmo marcador de conteúdo não fiável de uma
página web obtida da internet, até que o tenhas revisto tu mesmo.

O `update` fica preso à fonte exata de onde a skill foi instalada. Se o registo de um
tap passar a apontar esse nome para uma fonte *diferente* mais tarde, o `update`
recusa-se a seguir, em vez de o fazer em silêncio. Uma skill com o mesmo nome vinda de
outro sítio só consegue substituir a já instalada através de um `install --force`
explícito, nunca de uma atualização de rotina.

## Skills, plugins e scripts

Skills, plugins e scripts funcionam em conjunto, e é essa combinação que permite pedir
a um agente, em linguagem simples, algo que ele ainda não sabe fazer.

Juntando [plugins](../plugins/) ao `enable_tool`, dá para pedir pela conversa que o
agente instale uma ferramenta que faça X: ele lê a skill `install-tool`, escreve o
plugin em `plugins/<nome>.exs`, ativa a ferramenta em si mesmo, e já começa a usá-la,
sem precisar de reiniciar nada.

Para trabalho complexo ou de vários passos, o agente não tenta fazer tudo à mão. A
ferramenta `run_script` deixa-o escrever um programa curto (Python, Node, Ruby, Bash,
ou Elixir, este último sempre disponível) e correr esse programa, recebendo de volta
stdout, stderr e o código de saída para conseguir iterar sobre os erros. Os scripts que
compensam ficam guardados em `scripts/` e são reaproveitados mais tarde, bastando
passar ao `run_script` uma referência `file:`. E quando o agente descobre *como* fazer
uma tarefa recorrente, ler um PDF ou tratar de uma folha de cálculo, escreve para si
próprio uma skill em `skills/<nome>.md`. É a skill `write-a-script` que ensina esse
ciclo completo.
