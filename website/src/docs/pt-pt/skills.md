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

É precisamente essa indireção que importa. O agente transporta dezenas de
procedimentos pagando apenas uma linha de contexto por cada um, e abre a versão
longa exatamente quando o trabalho o exige. O resumo é a primeira linha não
vazia do ficheiro, por isso essa linha de abertura deve dizer quando a skill se
aplica.

<div class="note"><strong>A ferramenta skill.</strong> O agente precisa da ferramenta <code>skill</code> na sua lista de ferramentas para ler skills. Sem ela, as skills ficam listadas no contexto mas nunca são abertas.</div>

## Skills nativas

Estas vêm com o Pepe, em `priv/skills/`:

- **`skill-creator`** - como criar, editar, auditar e melhorar skills (a meta-skill).
- **`install-tool`** - escrever uma ferramenta em plugin e ativá-la pela conversa.
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

### Empacotar uma skill com scripts

Uma skill também pode vir como um pequeno pacote em vez de um único ficheiro:
uma pasta `<nome>/` com `SKILL.md` (o doc de entrada, lido exatamente como um
`<nome>.md` solto) ao lado do que mais precisar, tipicamente uma pasta
`scripts/`.

```bash
~/.pepe/skills/publicar-release/
  SKILL.md
  scripts/marcar-e-publicar.sh
```

Os ficheiros empacotados nunca são copiados para outro lado: o agente chega
até eles no próprio sítio, do mesmo modo que já chega ao workspace partilhado
ou a um plugin instalado, passando ao `run_script` (ou `read_file`) um
caminho no formato `skills/<nome>/scripts/<ficheiro>`. Aponta as instruções
do próprio `SKILL.md` para esse caminho e o script corre exatamente como foi
empacotado, em vez de o agente o reescrever do zero no primeiro pedido, em
cada sessão.

Uma skill instalada pelo `manage_skill`/`mix pepe skill install` (abaixo)
traz o pacote inteiro consigo automaticamente quando a fonte tem um: um
`SKILL.md` na raiz do que foi instalado é o que o marca como pacote; tudo o
resto sem isso continua a instalar como um único `<nome>.md`, exatamente
como antes. Todo o ficheiro de um pacote é escaneado por segurança antes de
instalar, não só o doc: o `SKILL.md` recebe o escaneamento de injeção de
prompt do costume, e cada script empacotado recebe o mesmo escaneamento
profundo que o código de um plugin recebe.

### Instalar uma vinda de fora

Dois caminhos, dependendo de onde ela vem. Um agente com a ferramenta
`manage_skill` usa-a para tudo o que o marketplace conseguir resolver: um nome
no registo incluído ou num tap, ou uma referência do
[PepeHub](https://hub.pepe-agent.com) (`@handle/nome`, ou o URL da própria
página). É a mesma instalação consciente do registo que o `mix pepe skill
install` faz, com confiança e proveniência registadas da mesma forma. Para uma
fonte sem nenhuma entrada em registo (um URL solto, um gist, um repositório
avulso), a skill `install-skill` ensina o agente a ir buscá-la manualmente. Em
ambos os casos, texto de skill vindo de fora é entrada não fiável: o agente
analisa-o com a ferramenta `scan_skill` antes de o gravar em disco. A análise
sinaliza injecção de prompt, exfiltração de segredos, comandos destrutivos,
persistência e ofuscação: uma segunda verificação, não um substituto para leres
o conteúdo, e nunca instala nada por si própria.

## Instalar a partir de um marketplace

`manage_skill` (acima) é o caminho conversacional para tudo o que os
registos/PepeHub conseguirem resolver. `mix pepe skill` é o caminho do
operador para os mesmos registos, com a mesma pesquisa e história de
atualização:

```bash
pepe skill search release            # pesquisa em cada tap mais o registo incluído
pepe skill install cut-a-release     # instala pelo nome
pepe skill install @jhonathas/google-workspace   # ou uma referência do PepeHub (vê abaixo)
pepe skill install cut-a-release --source https://example.com/cut-a-release.md   # ou diretamente
pepe skill update cut-a-release      # volta a obtê-la a partir da fonte exata de onde foi instalada
pepe skill tap add https://github.com/a-tua-equipa/pepe-skills   # adiciona um registo além do incluído
```

Um nome no formato `@handle/nome` (ou o próprio URL da página do pacote,
copiado diretamente do [PepeHub](https://hub.pepe-agent.com)) resolve contra o
PepeHub em si, o registo de plugins/skills do Pepe, em vez do registo incluído
ou de um tap: verificado primeiro, já que nenhuma entrada incluída ou de tap
usa esse formato. É instalada sob o slug puro do pacote (`google-workspace`,
não `@jhonathas/google-workspace`), o nome que todos os outros comandos de
skill e a ferramenta `skill` usam. Apontar `skill install` para um nome que na
verdade é um plugin no PepeHub, não uma skill, falha com uma mensagem clara a
indicar `plugin install` em vez disso.

Cada instalação passa pela mesma análise de segurança estática que
`manage_skill`/`install-skill` usam; um veredito perigoso é recusado a menos
que passes `--force`. A confiança é `"official"` para o registo incluído no
próprio repositório (curado por quem mantém o Pepe) e para um pacote do
PepeHub que o próprio PepeHub marcou manualmente como oficial. Tudo o que é
resolvido através de um tap que adicionaste, um pacote do PepeHub sem essa
marca, ou instalado com `--source`, é `"community"`: quando um agente o lê
com a ferramenta `skill`, o seu conteúdo vem envolvido no mesmo marcador de
conteúdo não fiável que uma página web obtida já carrega, até tu próprio o
teres revisto.

O `update` fica fixado à fonte exata a partir da qual a skill foi instalada - se o registo de
um tap depois apontar esse nome para uma fonte *diferente*, o `update` recusa-se em vez de a
seguir em silêncio. Uma skill com o mesmo nome vinda de outro lado só pode substituir uma já
instalada através de um `install --force` explícito, nunca de uma atualização de rotina.

## Skills, plugins e scripts

Os três pontos de extensão compõem-se, e juntos são o que permite pedir a um
agente, em linguagem natural, algo que ele ainda não sabe fazer.

Combinado com [plugins](../plugins/) e o `enable_tool`, podes pedir pela conversa
que o agente instale uma ferramenta que faça X. Ele lê a skill `install-tool`,
escreve o plugin em `plugins/<nome>.exs`, ativa a ferramenta em si mesmo e
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
