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

É isso que mantém as skills baratas. Um agente pode conhecer dezenas de
procedimentos sem que eles pesem na conversa, porque cada um custa uma única
linha até o momento em que o trabalho realmente pede por ele. O resumo é
simplesmente a primeira linha não vazia do arquivo, então essa linha de
abertura deve dizer quando a skill se aplica.

<div class="note"><strong>A ferramenta skill.</strong> O agente precisa da ferramenta <code>skill</code> na sua lista de ferramentas para ler skills. Sem ela, as skills ficam listadas no contexto mas nunca são abertas.</div>

## Skills nativas

Estas já vêm com o Pepe, em `priv/skills/`:

- **`skill-creator`**: como criar, editar, auditar e melhorar skills (a meta-skill).
- **`install-tool`**: escrever uma ferramenta em plugin e habilitá-la pela conversa.
- **`write-a-script`**: resolver tarefas complexas escrevendo e salvando um programa para rodar.
- **`manage-routing`**: alterar rotas entre agentes com `set_route`.
- **`handle-media`**: entender uma entrada de voz, áudio, imagem ou arquivo (transcrever, ler), instalando o que for preciso.
- **`install-skill`**: instalar uma skill a partir de uma URL, um gist, um repositório ou outro Pepe.
- **`create-watch`**: criar um watch durável do tipo "verifique X e me avise quando acontecer".

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

## Instalando de um marketplace

`install-skill` (acima) é o caminho conversacional: um agente traz uma skill de um link que
você dá a ele. `mix pepe skill` é o caminho do operador, com um registro para buscar e uma
história de atualização:

```bash
pepe skill search release            # busca em cada tap mais o registro embutido
pepe skill install cut-a-release     # instala pelo nome
pepe skill install cut-a-release --source https://example.com/cut-a-release.md   # ou diretamente
pepe skill update cut-a-release      # busca de novo da fonte exata de onde foi instalada
pepe skill tap add https://github.com/seu-time/pepe-skills   # adiciona um registro além do embutido
```

Toda instalação passa pela mesma varredura de segurança estática que `install-skill` usa; um
veredito perigoso é recusado a menos que você passe `--force`. A confiança é `"official"` só
para o registro embutido no próprio repositório (curado por quem mantém o Pepe, vazio por
padrão hoje: ainda não existe um registro hospedado, só o mecanismo). Tudo o que é resolvido
por um tap que você adicionou, ou instalado com `--source`, é `"community"`: quando um agente
lê pela ferramenta `skill`, o conteúdo vem embrulhado no mesmo marcador de conteúdo não
confiável que uma página web buscada já carrega, até você mesmo ter revisado.

`update` fica fixado na fonte exata de onde a skill foi instalada. Se o registro de um tap
depois apontar aquele nome para uma fonte *diferente*, `update` se recusa em vez de seguir em
silêncio. Uma skill com o mesmo nome vinda de outro lugar só pode substituir uma já instalada
por um `install --force` explícito, nunca por uma atualização de rotina.

## Skills, plugins e scripts

Skills, plugins e scripts trabalham juntos, e é essa combinação que permite
pedir a um agente, em linguagem natural, algo que ele ainda não sabe fazer.

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
