---
title: Agentes
description: Descreva um agente uma única vez (instruções, modelo e ferramentas) e o Pepe cuida do resto, chamando o modelo e rodando ferramentas até chegar numa resposta de verdade.
---

## O que é um agente

Um agente é uma descrição curta que você escreve uma única vez: um nome, as
instruções que lhe dão uma personalidade (o system prompt), o modelo com que ele
pensa e a lista de ferramentas que pode chamar. Alguns ajustes extras completam o
conjunto (um limite de iterações, uma temperatura, com quem ele pode falar, quem
ele pode administrar), mas é isso, não tem mais nada. O agente em si não guarda
nenhuma lógica própria: quem faz o trabalho é o Pepe, chamando o modelo, rodando
as ferramentas que o modelo pedir, devolvendo os resultados e repetindo até
existir uma resposta final.

Cada agente é uma entrada dentro de um único arquivo JSON, `~/.pepe/config.json`.
Não existe banco de dados por trás disso. Dá para criar e editar agentes de três
formas, e as três escrevem no mesmo arquivo:

1. A ferramenta de linha de comando `pepe`.
2. O painel web.
3. Uma conversa comum, falando com um agente que já tenha a ferramenta de gestão
   correspondente.

Veja como um agente completo fica em disco:

```json
{
  "agents": {
    "assistant": {
      "description": "General-purpose helper",
      "model": "openrouter",
      "system_prompt": "Você é um assistente prestativo e direto.",
      "tools": ["bash", "read_file", "write_file", "web_search"],
      "auto_approve": [],
      "can_message": [],
      "can_manage": null,
      "hooks": [],
      "max_iterations": 12,
      "temperature": null
    }
  }
}
```

## Seu primeiro agente

Antes de raciocinar, um agente precisa de uma conexão de modelo. Se você ainda
não tem nenhuma, a configuração guiada cuida de escolher um provedor, fazer
login e escolher um modelo:

```bash
pepe setup
```

Depois é só definir um agente, com um prompt e algumas ferramentas:

```bash
pepe agent add assistant \
  --model openrouter \
  --prompt "Você é um assistente prestativo e direto." \
  --tools bash,read_file,write_file,web_search
```

Rode um prompt avulso nele. A resposta vai sendo transmitida para o seu terminal
à medida que é produzida:

```bash
pepe run assistant "Quais arquivos existem no diretório atual?"
```

Esse comando sozinho já dispara o ciclo inteiro: o agente decide que precisa
olhar o sistema de arquivos, chama a ferramenta `list_dir` ou `bash`, lê o
resultado e responde em linguagem natural.

<div class="note"><strong>Pelo painel.</strong> A seção de Agentes do painel web
faz a mesma coisa com um formulário: nome, personalidade, modelo, uma lista de
seleção de ferramentas e o escopo de administração. Ela grava a mesma entrada em
<code>~/.pepe/config.json</code>, então dá para combinar livremente a CLI, o
painel e a edição manual.</div>

### Faça pela conversa

Qualquer agente com a ferramenta `manage_agent` pode criar e configurar outros
agentes direto pela conversa. É assim que o primeiríssimo agente (veja "O agente
dono" mais abaixo) deixa você montar o resto da sua frota sem precisar tocar na
CLI. Uma mensagem como esta já basta:

```text
Crie um agente chamado researcher. Dê a ele uma persona focada em pesquisa
cuidadosa na web, aponte para o modelo openrouter e habilite web_search e
fetch_url.
```

O agente chama `manage_agent` com `action: "create"`, e na sequência
`set_persona`, `set_model` e `add_tool` para cada capacidade nova. Por ser uma
ferramenta de risco, `manage_agent` passa pela barreira de permissão: numa
superfície que consegue perguntar (o console, um canal de chat), o Pepe pede
para você autorizar a mudança antes de escrevê-la, e a própria ferramenta já vem
instruída a confirmar o plano com você primeiro. Um agente só consegue gerir os
agentes dentro do seu escopo `can_manage` (tratado mais abaixo em
[Administrar agentes](#administrar-agentes)); pedir a ele para mexer em alguém
fora desse escopo é recusado com educação.

## Os campos, um por um

| Campo | O que faz | Padrão |
|-------|--------------|---------|
| `name` | A identidade do agente e a chave sob a qual ele fica armazenado e endereçável. Dentro de um projeto vira um identificador como `acme/assistant` (veja abaixo). O agente também carrega um id interno estável, então esse nome pode mudar sem quebrar nenhum vínculo. | obrigatório |
| `description` | Uma nota curta, só para humanos lerem. Nunca é enviada ao modelo. | nenhum |
| `model` | O nome de uma conexão de modelo. Deixe sem definir para cair no modelo padrão do projeto. | padrão do projeto |
| `system_prompt` | A personalidade e as instruções com que o agente roda. | `Você é o Pepe, um agente de IA prestativo.` (um prompt inicial) |
| `langfuse_prompt` | Busca a persona no prompt com esse nome no [Langfuse](#gerenciando-uma-persona-pelo-langfuse), em vez de usar `system_prompt`. | `null` (desligado) |
| `tools` | A lista de ferramentas que este agente pode chamar. Só essas chegam a ser oferecidas ao modelo. | todas as ferramentas: um agente novo já nasce com tudo habilitado, e você remove o que não quiser |
| `auto_approve` | Ferramentas que este agente pode executar sem pedir permissão. `["*"]` libera todas. | `[]` |
| `can_message` | Outros agentes para os quais este pode mandar mensagem (uma rota direcionada). | `[]` |
| `can_manage` | Quais agentes este pode administrar. Veja [Administrar agentes](#administrar-agentes). | `null` (só ele mesmo) |
| `hooks` | Transformações a aplicar no fluxo de mensagens, como a censura de dados pessoais. | `[]` |
| `max_iterations` | O teto rígido de quantas rodadas de modelo mais ferramenta cabem num turno. | `12` |
| `temperature` | Temperatura de amostragem passada ao modelo. Sem definir, usa o padrão do próprio provedor. | padrão do provedor |
| `triage_model` | Uma conexão de modelo que avalia a complexidade antes do primeiro turno de uma sessão. Veja [Roteamento de modelo por complexidade](#roteamento-de-modelo-por-complexidade). | nenhum (desligado) |
| `simple_model` | A conexão de modelo para a qual descer quando o `triage_model` julga uma conversa simples. | nenhum |

## Como roda o ciclo de chamada de ferramentas

Quando você manda uma mensagem para um agente, o Pepe segue esta sequência:

1. Chama o modelo com a conversa até ali e uma descrição de cada ferramenta que o
   agente pode chamar.
2. Se o modelo devolver uma resposta final, ela é retornada e o ciclo termina
   ali.
3. Se em vez disso o modelo pedir para chamar uma ou mais ferramentas, o Pepe
   executa cada uma, anexa os resultados à conversa e volta ao passo 1.
4. Isso se repete até o modelo entregar uma resposta final ou o ciclo bater no
   teto de `max_iterations`. Batendo o teto, o turno termina com a nota
   `(stopped: max iterations reached)`.

Como os resultados voltam para dentro da conversa, o modelo consegue encadear
passos: ler um arquivo, perceber que precisa de outro, ler esse também, e só
então escrever um resumo, tudo dentro de um único turno. O limite de iterações é
a proteção que evita um agente confuso ficando em loop para sempre.

Antes da chamada ao modelo existem ainda outras duas barreiras. Um agente cujo
modelo exige censura de dados se recusa a rodar sem um hook de censura ativado, e
um projeto que já bateu o teto de gasto mensal (ou o teto separado de mensagens
de clientes por mês) para exatamente aqui: nada de chamada nova ao modelo, nada
de resposta nova. As duas encerram o turno de forma limpa, com um erro claro, em
vez de deixar passar em silêncio; veja Cobrança e limites para configurar esses
tetos.

<div class="note"><strong>Transmissão e eventos.</strong> Enquanto o ciclo roda,
ele emite eventos de ciclo de vida: um fragmento de texto transmitido
(<code>assistant_delta</code>), uma mensagem completa do assistente
(<code>assistant</code>), uma chamada de ferramenta (<code>tool_call</code>), uma
ferramenta recusada (<code>tool_denied</code>), um resultado de ferramenta
(<code>tool_result</code>), uma troca para um modelo de fallback
(<code>failover</code>), um registro de uso de tokens (<code>usage</code>), uma
resposta final (<code>done</code>) ou um erro (<code>error</code>). A CLI, o
WebSocket e os canais de mensagens renderizam tudo isso ao vivo, e é por isso que
você vê a digitação e a atividade das ferramentas acontecendo em tempo real, em
vez de receber um único bloco no final.</div>

## Conversas longas: compactação

Uma conversa não cresce para sempre dentro da janela de contexto do modelo (a
quantidade de conversa que um modelo consegue enxergar de uma vez). Assim que o
tamanho estimado ultrapassa cerca de 60% dela, o Pepe substitui o **meio** do
histórico por um resumo curto que o próprio modelo escreve, preservando palavra
por palavra o system prompt e os turnos mais recentes. Isso é automático e não
pede nenhuma configuração: a transcrição completa segue guardada (veja Traces),
só o que vai para o modelo é que fica condensado.

Por padrão, esse resumo acontece **uma vez**, do zero, sempre que o limite volta
a ser cruzado. Para a maioria das conversas isso basta, mas uma que se estende
demais pode bater nesse limite repetidas vezes, resumindo de novo um meio que só
cresceu. Um agente pode optar pelo `micro_compaction` como alternativa: uma vez
cheia a janela, ele dobra a cada turno exatamente a troca mais antiga ainda não
resumida dentro de um resumo contínuo, trocando uma parada periódica por um custo
pequeno e constante. O trade-off é real, e por isso vem desligado por padrão: uma
vez ativo, o resumo contínuo muda a cada turno, então o provedor deixa de
conseguir reaproveitar a cópia em cache do início inalterado do prompt entre uma
chamada e outra. Vale a pena numa conversa longa o bastante para bater o limite
com frequência; não numa curta.

```bash
pepe agent add support --micro-compaction ...
```

Ou ligue num agente já existente pelo editor de agentes do painel, ou pedindo a
um agente com a ferramenta `manage_agent` que ligue o interruptor
`micro_compaction` em outro.

## Mencionar o que mais ele sabe fazer

É comum alguém usar um agente para uma única coisa e nunca descobrir que ele
também consegue vigiar algo por mudanças, rodar uma tarefa recorrente, ou
trabalhar em direção a um objetivo até ele realmente sair do papel; nada expõe
isso além do que a própria persona do agente eventualmente mencionar. O
`capability_nudge`, desligado por padrão, deixa o agente acrescentar uma frase
curta e natural apontando para uma funcionalidade relacionada logo depois de
ajudar com algo, só quando ela realmente se encaixa: não é um menu, e não
acontece em todo turno. Descoberta pelo uso, não uma avalanche de onboarding.

```bash
pepe agent add support --capability-nudge ...
```

Deixe desligado num agente que precisa continuar direto e transacional; ligue
pelo editor de agentes do painel, ou pedindo a um agente com a ferramenta
`manage_agent` que ligue o interruptor `capability_nudge` em outro.

## Aprender com o que ele faz

Um agente que descobre um procedimento do zero costuma jogar a descoberta fora: ninguém
para no meio da tarefa para pedir que ela seja guardada. O `skill_learning`, desligado por
padrão, deixa que o próprio agente levante o assunto. Depois de uma tarefa que deu
trabalho de verdade (pelo menos quatro chamadas de ferramenta bem-sucedidas, em pelo menos
duas ferramentas, sem nenhuma skill existente consultada), ele pode oferecer, em uma
frase, guardar aquele caminho como skill, para que da próxima vez seja direto. E quando
ele segue uma skill que o leva para o lugar errado, pode oferecer corrigir essa skill com
o que a falha ensinou, como uma edição na que já existe.

```bash
pepe agent add ops --skill-learning ...
```

A oferta é a funcionalidade inteira: nenhum arquivo de skill é escrito ou alterado sem um
sim explícito. Diferente do `capability_nudge`, isso não custa nada num turno comum,
porque não há parágrafo extra no prompt de sistema, só uma nota curta nos turnos que
cruzam a régua. Veja [Skills](../skills/) para o que o agente escreve depois.

## Ferramentas e a barreira de permissão

Uma ferramenta é uma capacidade. Um agente só consegue fazer o que a lista
`tools` dele libera: dê `read_file` mas não `write_file`, e ele olha mas não
mexe.

Liste todas as ferramentas disponíveis na sua instalação:

```bash
pepe tools
```

O conjunto embutido já cobre o essencial:

| Ferramenta | O que faz |
|------|--------------|
| `bash` | Executa um comando de shell. |
| `run_script` | Escreve e roda um programa curto em Python, Node, Ruby ou Elixir. |
| `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir` | Trabalham com arquivos no workspace do agente. |
| `fetch_url`, `web_search` | Leem uma página web ou buscam na web. |
| `send_file` | Entrega um arquivo que o agente produziu, no canal atual. |
| `send_to_agent` | Manda mensagem para outro agente (sujeito a `can_message`). |
| `ask_user` | Pede para você escolher entre algumas opções, com botões ou menu de verdade onde o canal permite. |
| `schedule_task`, `watch` | Criam tarefas recorrentes e vigias de "me avise quando X" de uma vez só. |
| `manage_agent`, `rename_agent`, `enable_tool`, `set_route` | Gerenciam agentes, ferramentas e roteamento pelo chat. |
| `manage_channel`, `end_session` | Conectam e fecham canais de mensagens pelo chat. |
| `manage_mcp`, `scan_skill`, `skill` | Adicionam servidores de ferramentas externas e skills. |
| `manage_plugin` | Instala, varre, lista e remove plugins da comunidade (ferramentas, canais) pelo chat. |
| `config_get`, `config_set`, `doctor` | Inspecionam e alteram a configuração sob proteções, e rodam diagnósticos. |

Algumas ferramentas só leem coisas, então rodam livremente: `read_file`,
`list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`,
`scan_skill` e `send_to_agent` (esta última é regida pelas rotas `can_message`
em vez de pela barreira). Todo o resto, incluindo qualquer ferramenta vinda de
plugin, é tratado como arriscado e passa por uma barreira de permissão antes de
rodar.

Quando uma ferramenta arriscada ainda não foi pré-aprovada e a superfície
consegue perguntar a uma pessoa (o console, um canal de chat), o Pepe pede para
você autorizar a chamada. As respostas possíveis são:

- Permitir uma vez. Pergunta de novo na próxima.
- Permitir pelo resto desta execução. Só aparece enquanto a execução tiver
  ingerido conteúdo vindo de fora (veja
  [Segurança e ambiente isolado](../security/)): o único tipo de pré-aprovação
  que de fato continua valendo durante essa janela.
- Permitir pelo resto desta sessão. Guardado em memória, esquecido ao reiniciar.
- Permitir sempre. Persistido no agente, adicionando a ferramenta à lista
  `auto_approve` dele.
- Negar. Nunca é lembrado, então volta a perguntar da próxima vez.

Coloque você mesmo uma ferramenta em `auto_approve` para já pular o pedido desde
o início. Em superfícies sem ninguém para perguntar (a API HTTP, um webhook, uma
tarefa cron), uma ferramenta com barreira é simplesmente recusada em vez de
rodar sem supervisão: só o que já está em `auto_approve` chega a executar.

### Pedindo para você escolher

Algumas perguntas são melhor respondidas com um toque do que com uma resposta
digitada. O `ask_user` deixa um agente apresentar uma pergunta de múltipla
escolha de verdade e receber a escolha de volta dentro do mesmo turno, em vez de
adivinhar ou encerrar o turno na esperança de que a próxima mensagem responda
exatamente o que foi perguntado. No Telegram isso aparece como botões inline
reais; no console, como um menu numerado; no chat do painel, como opções
clicáveis. Roda livremente, já que perguntar não carrega risco nenhum e por isso
nunca passa pela barreira de permissão, mas só funciona onde existe uma pessoa
interativa para responder: a API HTTP, um webhook ou uma execução não
supervisionada de cron/watch recusam a chamada na hora, em vez de ficar
esperando um botão que ninguém vai apertar.

### Faça pela conversa

Um agente que acabou de instalar um plugin, ou que quer uma capacidade que ainda
não tem, pode ativar uma ferramenta em si mesmo com `enable_tool`:

```text
Enable the web_search tool for yourself.
```

O agente chama `enable_tool` com o nome da ferramenta. Ela já precisa existir
como embutida ou como plugin instalado, e a mudança entra em vigor na próxima
mensagem do agente. Como `enable_tool` também tem barreira, você autoriza a
concessão antes dela ser escrita.

## A conexão de modelo

`model` nomeia uma conexão que você definiu com `pepe model add`. Deixar sem
definir faz o agente usar o modelo padrão do projeto, então dá para apontar um
conjunto inteiro de agentes para um provedor e trocar todos de uma vez mudando
só o padrão.

Uma conexão de modelo pode carregar uma cadeia de fallback. Quando o modelo
primário do agente falha com um erro passageiro (um limite de taxa, um tempo
esgotado, uma queda de rede ou um 5xx), o Pepe desce pela cadeia e tenta de novo
no próximo modelo, emitindo um evento `failover` nesse meio-tempo. Já um erro
grave, como uma chave de API errada ou uma requisição malformada, falha na hora,
porque nenhum outro endpoint resolveria isso mesmo.

O Pepe fala com os provedores pelo protocolo Chat Completions da OpenAI, então
qualquer endpoint compatível com OpenAI funciona sem precisar mudar código.

### Faça pela conversa

Um agente com a ferramenta `manage_agent` pode reapontar um modelo que
administra:

```text
Point the researcher agent at the groq-fast model.
```

O agente chama `manage_agent` com `action: "set_model"`. O modelo de destino
precisa ser uma conexão já configurada, e a mudança passa pela barreira de
permissão como qualquer outra edição de configuração.

## Roteamento de modelo por complexidade

O `model` do próprio agente é tratado como a boa opção padrão. Opcionalmente,
uma primeira verificação rápida e barata pode julgar se uma conversa é simples o
bastante para *descer* para um modelo mais barato, antes mesmo de o turno de
verdade começar. Não precisa de nenhum agente extra para configurar, só dois
campos:

- `triage_model`: uma conexão de modelo que classifica a mensagem recebida com
  um prompt fixo e embutido (não uma persona que você escreve); o Pepe
  simplesmente procura a palavra "SIMPLE" na resposta.
- `simple_model`: a conexão de modelo para a qual descer, e manter pelo resto da
  sessão, assim que o veredito da triagem for simples.

```bash
pepe agent add assistant \
  --model modelo-forte-e-caro \
  --triage-model modelo-barato-e-rapido \
  --simple-model modelo-do-dia-a-dia \
  --prompt "..." \
  --tools bash,read_file,web_search
```

A triagem roda uma única vez, no primeiro turno de uma sessão, e nunca mais
naquela mesma sessão; assim que uma conversa é julgada simples, ela permanece no
modelo mais barato pelo resto da conversa (o mesmo mecanismo que o comando
`/model` usa para trocar o modelo de uma sessão, só que disparado
automaticamente em vez de na mão). Um veredito complexo não muda nada: a sessão
segue no próprio modelo do agente, exatamente como rodaria sem `triage_model`
nenhum definido.

A triagem é uma otimização de melhor esforço, nunca uma dependência. Se o modelo
de triagem não existe, está inacessível, ou simplesmente demora demais (com um
teto de poucos segundos), o turno segue no próprio modelo do agente, em
silêncio; uma queda na triagem nunca bloqueia nem quebra uma conversa. O
`simple_model` também precisa estar definido para a triagem sequer rodar, já que
sem ele não haveria para onde descer.

Cada veredito aparece como um passo próprio no Trace daquele turno (o replay de
cada execução no painel), junto de qualquer hook de privacidade que tenha rodado
sobre a mensagem, para você ver exatamente por que uma sessão terminou num
modelo e não no outro.

## O agente padrão

Um agente por projeto pode ser o padrão, e é ele que roda quando você não nomeia
nenhum:

```bash
pepe run "resuma este repositório"
```

O primeiro agente que você cria no projeto default vira automaticamente o
padrão. Mude isso a qualquer momento:

```bash
pepe agent default assistant
```

## O agente dono

O primeiríssimo agente, criado durante a configuração inicial, é o agente do
próprio dono, e ele já nasce plenamente capaz: recebe todas as ferramentas, é
superadministrador sobre todos os outros agentes (`can_manage` é `["*"]`), e
todas as suas chamadas de ferramenta já chegam pré-aprovadas (`auto_approve` é
`["*"]`), então ele nunca precisa parar para perguntar. É isso que permite fazer
trabalho de verdade pela conversa desde o primeiro minuto, incluindo criar e
configurar todos os agentes seguintes. Os agentes que você adiciona depois vêm
mais restritos por padrão: você escolhe as ferramentas deles, eles administram
só a si mesmos, e as chamadas de risco passam pela barreira de permissão.

## Deixar os agentes conversarem entre si

`can_message` é uma lista de mão única: se o agente A inclui o agente B, então A
pode mandar B uma mensagem com a ferramenta `send_to_agent`, mas o contrário não
está implícito. Adicione uma rota pela CLI:

```bash
pepe agent route triage assistant
```

Agora `triage` pode passar trabalho para `assistant`. Remova a rota com
`--remove`. As rotas nunca cruzam a fronteira de um projeto; a CLI recusa
`A -> B` sempre que os dois estiverem em projetos diferentes.

### Faça pela conversa

Um agente com a ferramenta `set_route` pode mudar o roteamento direto pela
conversa. `from` assume por padrão o próprio agente que está chamando:

```text
Allow yourself to message the billing agent.
```

O agente chama `set_route` com `action: "allow"` e `to: "billing"`. Como o
roteamento é direcionado, isso não deixa `billing` responder de volta. E, por
editar a configuração, `set_route` passa pela barreira de permissão, então você
autoriza a mudança.

## Administrar agentes

`can_manage` controla quais agentes um agente pode administrar (criar, editar,
reconfigurar, treinar) pela ferramenta `manage_agent`. Vem fechado por padrão, e
o significado é preciso:

- Sem definir (`null`): o agente só pode administrar a si mesmo.
- Vazio (`[]`, definido com `--can-manage none`): não pode administrar ninguém,
  nem a si mesmo. Um filho trancado, por exemplo um agente voltado ao cliente
  que não pode se alterar.
- Uma lista de nomes: exatamente esses agentes, e mais ninguém. Inclua o próprio
  nome se quiser que ele também administre a si mesmo.
- `["*"]` (definido com `--can-manage "*"`): todos os agentes. Um
  superadministrador explícito.

Conceda autoridade de gestão diretamente:

```bash
pepe agent manage supervisor "*"
```

### Faça pela conversa

Um agente administrador usa o `manage_agent` para moldar os agentes do seu
escopo. As ações dele são `list`, `get`, `create`, `set_persona`, `set_model`,
`add_tool`, `remove_tool` e `remember` (que anexa um fato duradouro à memória do
alvo). Por exemplo:

```text
Dê ao agente de suporte a ferramenta send_file e registre na memória dele que
reembolsos acima de 200 precisam de uma pessoa.
```

O agente chama `manage_agent` com `action: "add_tool"` e depois com
`action: "remember"`. Cada uma dessas ações tem barreira própria: o agente
propõe a mudança, você a autoriza, e só então ela é aplicada. Um agente também
pode se renomear com a ferramenta separada `rename_agent` ("De agora em diante,
se chame scout"), o que move o diretório do seu workspace e entra em vigor na
próxima mensagem. Renomear é seguro porque cada agente, como cada modelo e cada
projeto, carrega um id interno estável, e o nome é apenas um rótulo mutável:
toda referência a ele (rota, permissão, padrão, vínculo de cron, bot ou token) é
feita por esse id, então nada fica pendurado quando o rótulo muda.

## Agentes multiprojeto

Todo cliente (tenant) é um projeto. Sem criar nenhum projeto adicional, tudo
vive no projeto default (slug `default`), exatamente como sempre funcionou uma
instalação de cliente único. Adicione outro projeto para isolar um cliente: os
agentes dele, os workspaces, o espaço compartilhado, as conexões de modelo e o
roteamento ficam isolados de qualquer outro projeto.

A identidade real de um agente é o seu identificador. No projeto default esse
identificador é só o nome simples (`assistant`). Dentro de outro projeto ele
vem qualificado como `project/name` (`acme/assistant`), então o mesmo nome
simples pode ser reaproveitado em projetos diferentes sem colidir.

Crie um projeto e depois adicione agentes dentro dele com `--project`:

```bash
pepe project add acme --description "Acme Corp"

pepe agent add support \
  --project acme \
  --model openrouter \
  --prompt "Você é o agente de suporte da Acme." \
  --tools read_file,web_search
```

Adicione `--project acme` a qualquer comando de agente para agir dentro daquele
escopo. Nomes simples de pares em `--can-message` e `--can-manage` se resolvem
dentro do próprio projeto do agente, então as rotas nunca cruzam por acidente a
fronteira de um projeto. Cada projeto pode fixar o próprio modelo padrão e o
próprio agente padrão, ou compartilhar o provedor global do operador. Um agente
nunca é promovido a padrão global só por ser o primeiro criado dentro de um
projeto que não é o default.

## Gerir agentes pela CLI

```bash
# Cria um agente. Omita --tools para liberar todas as ferramentas; passe --tools "" para nenhuma.
pepe agent add NAME \
  --model MODEL \
  --prompt "..." \
  --tools t1,t2 \
  [--description "..."] \
  [--can-message b,c] \
  [--can-manage x,y | "*" | none] \
  [--hooks pii_redact] \
  [--max-iterations 12] \
  [--temperature 0.7] \
  [--triage-model MODEL] \
  [--simple-model MODEL] \
  [--default] \
  [--project PROJ]

# Lista agentes em um escopo, ou todos os agentes.
pepe agent list [--project PROJ | --all]

# Imprime o system prompt já totalmente montado - não só o campo de persona, tudo o
# que o Pepe constrói ao redor dele. Veja "Vendo exatamente o que o modelo vê" abaixo.
pepe agent prompt NAME [--project PROJ]

# Directed messaging: let FROM message TO.
pepe agent route FROM TO [--remove] [--project PROJ]

# Management authority: let ADMIN administer TARGET (or "*" for all).
pepe agent manage ADMIN TARGET [--remove] [--project PROJ]

# Rename an agent and move its workspace directory.
pepe agent rename OLD NEW

# Delete an agent.
pepe agent remove NAME [--project PROJ]

# Set the default agent for a scope.
pepe agent default NAME [--project PROJ]
```

## Rodar um agente

O mesmo agente pode ser alcançado de quatro jeitos.

**De uma vez só, pela CLI.** Sem sessão, transmite direto para o stdout.

```bash
pepe run assistant "your prompt here"
```

**Console interativo.** Mantém a conversa, então o contexto passa de um turno
para o outro. Retome ou separe sessões de console com `--session KEY`.

```bash
pepe tui assistant
```

**Por HTTP e WebSocket.** Suba o servidor e chame a API compatível com OpenAI,
ou abra um WebSocket de transmissão. O campo `model` da requisição é quem nomeia
o agente.

```bash
pepe serve --port 4000
```

```http
POST /v1/chat/completions
Content-Type: application/json

{
  "model": "assistant",
  "messages": [{ "role": "user", "content": "your prompt here" }]
}
```

O WebSocket fica em `ws://localhost:4000/socket/websocket`, e a verificação de
saúde em `GET /health`.

**Por um canal de mensagens.** Vincule um agente a uma conexão de Telegram,
WhatsApp, Slack, Discord, Microsoft Teams ou Google Chat, ou a um webhook de
entrada genérico, e ele passa a responder ali com o mesmo ciclo e as mesmas
ferramentas.

## Gerenciando uma persona pelo Langfuse

Defina `langfuse_prompt` com o nome de um prompt, e a persona desse agente passa
a vir do [Langfuse](../langfuse/) em vez do `system_prompt`/`SOUL.md` próprio:
edite o prompt no Langfuse e a mudança chega ao Pepe em poucos minutos, sem
redeploy e sem tocar no `config.json`.

```bash
pepe agent add support --langfuse-prompt support-persona
```

É opt-in por agente: um sem `langfuse_prompt` definido fica totalmente
inalterado, e se a busca falhar (endpoint inacessível, nome que não resolve),
ele cai direto de volta para a persona local. Configuração e credenciais:
[Langfuse](../langfuse/).

## Vendo exatamente o que o modelo vê

O campo `system_prompt` é só a semente. O que de fato vai para o modelo como
mensagem de sistema também inclui os arquivos de persona, identidade e boot do
agente, se ele tiver algum, um contrato de comportamento curto, o horário atual
e um índice dos docs e skills que ele conhece, e nada disso aparece se você só
ler o campo em disco. Para ver a coisa toda, montada exatamente do jeito que uma
conversa real receberia:

```bash
pepe agent prompt NAME
```

A página de edição do agente no painel tem a mesma visão, em **Prompt montado**,
recolhida por padrão porque pode ficar longa.
