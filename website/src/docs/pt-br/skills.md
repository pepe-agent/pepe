---
title: Skills
description: Instruções reutilizáveis, instaláveis, que ensinam fluxos de trabalho repetíveis a um agente.
---

Uma skill é um documento de instruções sob demanda: um arquivo Markdown que ensina um
*procedimento* ao agente, como instalar uma ferramenta ou como lidar com uma mensagem
de áudio. É assim, sem uma única linha de código mudar, que um agente aprende a fazer
algo novo.

## Fica listada, não carregada

Uma skill nunca é colada por inteiro dentro do system prompt. No contexto do agente
aparecem só o nome dela e um resumo de uma linha; quando o assunto surge de fato, é aí
que o agente chama a ferramenta `skill` com esse nome, lê o documento inteiro e passa
a seguir o que está escrito.

É justamente esse mecanismo que mantém as skills baratas: um agente consegue conhecer
dezenas de procedimentos sem que isso pese na conversa, porque cada um custa uma única
linha até o exato momento em que o trabalho pede por ele. O resumo, aliás, não é nada
além da primeira linha não vazia do arquivo, então vale escrever essa abertura já
dizendo quando aquela skill se aplica.

<div class="note"><strong>A ferramenta skill.</strong> Só um agente com <code>skill</code> na própria lista de ferramentas consegue ler skills de verdade. Sem ela, elas continuam listadas no contexto, mas nunca chegam a ser abertas.</div>

## Skills nativas

Já vêm junto com o Pepe, dentro de `priv/skills/`:

- **`skill-creator`**: como criar, editar, auditar e melhorar skills, a meta-skill.
- **`install-tool`**: escrever uma ferramenta como plugin e habilitá-la pela conversa.
- **`write-a-script`**: resolver tarefas complexas escrevendo um programa e salvando-o para rodar depois.
- **`manage-routing`**: mudar rotas entre agentes usando `set_route`.
- **`handle-media`**: entender uma entrada de voz, áudio, imagem ou arquivo (transcrever, ler), instalando o que faltar para isso.
- **`install-skill`**: instalar uma skill a partir de uma URL, um gist, um repositório, ou outro Pepe.
- **`create-watch`**: montar um watch durável do tipo "verifica X e me avisa quando acontecer".

## Escrevendo as suas próprias

Skills de usuário ficam em `~/.pepe/skills/*.md`. Uma dessas sempre sobrepõe a nativa
de mesmo nome, então escrever seu próprio `handle-media.md` já substitui o que vem de
fábrica com o Pepe. A primeira linha não vazia do arquivo vira o resumo; tudo depois
dela é o procedimento em si, escrito em Markdown puro, pensado para o agente ler e
seguir.

```bash
~/.pepe/skills/publicar-release.md
```

Não existe passo de registro, nem precisa reiniciar nada: basta colocar o arquivo no
lugar, e a skill já aparece na lista do agente a partir da próxima mensagem.

### Deixando o próprio agente escrever

Um agente consegue escrever as próprias skills. Peça para ele guardar, como skill, o
jeito de fazer alguma coisa, e ele grava um novo `skills/<nome>.md`, guiado pela
`skill-creator`, que já entra na lista dele na hora.

> Você: funcionou. guarde como skill o processo de publicar uma release
>
> Agente: salvei skills/publicar-release.md. Vou segui-lo na próxima vez que você pedir uma release.

Isso é o que dá durabilidade ao conhecimento do agente: em vez de redescobrir o mesmo
procedimento a cada sessão, ele fica registrado assim que descoberto uma primeira vez.

### Empacotando uma skill com scripts

Em vez de um único arquivo, uma skill também pode vir como um pequeno pacote: uma
pasta `<nome>/` contendo um `SKILL.md` (o documento de entrada, lido exatamente como
um `<nome>.md` solto seria) junto de tudo mais que ela precisar, geralmente uma pasta
`scripts/`.

```bash
~/.pepe/skills/publicar-release/
  SKILL.md
  scripts/marcar-e-publicar.sh
```

Nada desses arquivos empacotados é copiado para outro lugar: o agente acessa tudo no
próprio local onde já está, do mesmo jeito que já acessa o workspace compartilhado ou
um plugin instalado, passando ao `run_script` (ou ao `read_file`) um caminho no
formato `skills/<nome>/scripts/<arquivo>`. Basta as instruções do `SKILL.md` apontarem
para esse caminho, e o script roda exatamente como foi empacotado, sem o agente
precisar reescrevê-lo do zero toda vez que uma nova sessão começa.

Quando instalada via `manage_skill`/`mix pepe skill install` (mais abaixo), uma skill
já traz o pacote inteiro automaticamente, desde que a fonte tenha um: o que marca algo
como pacote é justamente ter um `SKILL.md` na raiz do que está sendo instalado; sem
isso, continua instalando normalmente como um único `<nome>.md`, do jeito de sempre.
Todo arquivo de um pacote passa por varredura de segurança antes de instalar, e não só
o documento principal: o `SKILL.md` recebe a checagem de injeção de prompt de sempre, e
cada script empacotado recebe a mesma varredura profunda aplicada ao código de um
plugin.

### Instalando uma skill de fora

Existem dois caminhos possíveis, dependendo de onde ela vem. Um agente que tem a
ferramenta `manage_skill` usa isso para tudo que o marketplace conseguir resolver: um
nome no registro embutido, num tap, ou uma referência do
[PepeHub](https://hub.pepe-agent.com) (`@handle/nome`, ou até a própria URL da
página). É a mesma instalação com registro que `mix pepe skill install` faz, com
confiança e proveniência rastreadas exatamente da mesma forma. Já para uma fonte sem
nenhuma entrada em registro (uma URL avulsa, um gist, um repositório qualquer), é a
skill `install-skill` que ensina o agente a buscá-la manualmente. Em qualquer um dos
casos, texto de skill vindo de fora conta como entrada não confiável, então o agente
passa esse conteúdo pela ferramenta `scan_skill` antes de gravá-lo em disco. Essa
varredura sinaliza injeção de prompt, exfiltração de segredos, comandos destrutivos,
persistência e ofuscação; é uma segunda checagem, não um substituto para você mesmo
ler o conteúdo, e ela nunca instala nada por conta própria.

## Instalando a partir de um marketplace

`manage_skill`, já visto acima, é o caminho pela conversa para tudo que os registros
ou o PepeHub conseguem resolver. `mix pepe skill` é o caminho equivalente pelo lado do
operador, usando os mesmos registros, a mesma busca e a mesma lógica de atualização:

```bash
pepe skill search release            # busca em cada tap mais o registro embutido
pepe skill install cut-a-release     # instala pelo nome
pepe skill install @jhonathas/google-workspace   # ou uma referência do PepeHub (veja abaixo)
pepe skill install cut-a-release --source https://example.com/cut-a-release.md   # ou diretamente
pepe skill update cut-a-release      # busca de novo, na fonte exata de onde foi instalada
pepe skill tap add https://github.com/seu-time/pepe-skills   # adiciona um registro além do embutido
```

Um nome no formato `@handle/nome` (ou até a própria URL da página do pacote, copiada
direto do [PepeHub](https://hub.pepe-agent.com)) é resolvido contra o PepeHub em si,
que é o registro de plugins e skills do próprio Pepe, em vez do registro embutido ou
de um tap. Ele é checado primeiro, já que nenhuma entrada embutida ou de tap usa esse
formato de nome. A instalação acontece sob o slug puro do pacote (`google-workspace`,
e não `@jhonathas/google-workspace`), que é o nome usado depois por todo comando de
skill e pela própria ferramenta `skill`. Se você apontar `skill install` para um nome
que na verdade é um plugin no PepeHub, e não uma skill, a instalação falha com uma
mensagem clara indicando para usar `plugin install` em vez disso.

Toda instalação passa pela mesma varredura de segurança estática usada por
`manage_skill`/`install-skill`, e um veredito perigoso é recusado a menos que você
force com `--force`. O nível de confiança é `"official"` tanto para o registro
embutido no próprio repositório, curado pela equipe que mantém o Pepe, quanto para um
pacote do PepeHub que o próprio PepeHub marcou manualmente como oficial. Já tudo que
vem de um tap que você mesmo adicionou, de um pacote do PepeHub sem essa marca, ou
instalado via `--source`, entra como `"community"`: quando um agente lê esse conteúdo
pela ferramenta `skill`, ele chega embrulhado no mesmo marcador de conteúdo não
confiável usado numa página web buscada, e assim permanece até você revisar por conta
própria.

O comando `update` fica preso à fonte exata de onde a skill foi instalada. Se o
registro de um tap passar a apontar aquele mesmo nome para uma fonte *diferente*,
`update` se recusa a seguir em vez de trocar de fonte em silêncio. Uma skill de mesmo
nome vinda de outro lugar só consegue substituir a já instalada através de um
`install --force` explícito, nunca por uma atualização de rotina.

## Skills, plugins e scripts

Skills, plugins e scripts trabalham em conjunto, e é essa combinação que permite pedir
a um agente, em linguagem natural, algo que ele ainda não sabe fazer.

Junte isso a [plugins](../plugins/) e ao `enable_tool`, e dá para simplesmente pedir
pela conversa que o agente instale uma ferramenta capaz de fazer X. Ele lê a skill
`install-tool`, escreve o plugin em `plugins/<nome>.exs`, habilita a ferramenta nele
mesmo, e já passa a usá-la, sem precisar reiniciar nada.

Para trabalho complexo ou com várias etapas, o agente não insiste em fazer tudo na
mão. A ferramenta `run_script` permite escrever um programa curto (Python, Node, Ruby,
Bash ou Elixir, sendo que Elixir está sempre disponível) e rodá-lo, recebendo de volta
stdout, stderr e o código de saída para conseguir iterar em cima dos erros. Um script
que compensa manter é salvo em `scripts/` e reaproveitado depois, bastando passar ao
`run_script` uma referência `file:`. E quando o agente descobre *como* resolver uma
tarefa recorrente, seja ler um PDF ou processar uma planilha, ele mesmo escreve uma
skill para si em `skills/<nome>.md`. É justamente esse ciclo completo que a skill
`write-a-script` ensina.
