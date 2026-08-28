---
title: Delegação (fan-out)
description: A ferramenta delegate parte um trabalho amplo em vários workers paralelos e descartáveis, cada um com a sua própria janela de contexto, para que o conjunto demore o tempo da parte mais lenta, e não a soma de todas.
---

"Compara estes oito concorrentes" não é uma tarefa: são oito. E resolver isso numa única
conversa custa a dobrar: demora oito vezes mais, e cada página lida sobre o concorrente
um continua a ocupar a janela de contexto enquanto o modelo já vai no concorrente oito.
A janela acaba cheia de material que ninguém volta a olhar, e é a resposta final que sai
a perder com isso.

A ferramenta `delegate` reparte o trabalho por workers descartáveis, todos ao mesmo
tempo:

```
tu › compara as páginas de preços da stripe, da adyen e da mollie

agente › delegate(tasks: [
           "Lê stripe.com/pricing e indica a taxa de cartão e qualquer mínimo mensal.",
           "Lê adyen.com/pricing e indica a taxa de cartão e qualquer mínimo mensal.",
           "Lê mollie.com/pricing e indica a taxa de cartão e qualquer mínimo mensal."
         ])
```

Cada worker arranca do zero, com a sua própria janela de contexto e o seu próprio trace:
lê o que precisa, responde exatamente à pergunta que recebeu, e desaparece. Quem
delegou fica só com as três respostas, nunca com as três transcrições completas, e é por
isso que o trabalho cabe numa janela onde de outra forma não caberia. Como os workers
esperam pela rede ao mesmo tempo uns dos outros, o conjunto todo demora o tempo do mais
lento, não a soma de todos.

## Dar a ferramenta a um agente

Concede-se o `delegate` da forma habitual, incluindo-o na lista de ferramentas:

```bash
pepe agent add lead --model openrouter --tools fetch_url,read_file,delegate
```

## Um worker lê; não age

Um worker só herda as ferramentas que não pedem permissão nenhuma: `read_file`,
`list_dir`, `fetch_url`, `web_search` e semelhantes. Tudo o que escreve, executa, instala
ou apaga fica de fora antes mesmo de o worker arrancar, e um worker não consegue, por sua
vez, delegar mais trabalho.

Isto não é uma limitação a caminho de ser removida. Três workers a correr ao mesmo tempo
seriam três agentes a querer perguntar-te três coisas ao mesmo tempo, e "posso fazer
isto?" não é uma pergunta que faça sentido em triplicado. Mas o motivo mais de fundo é
outro: fan-out serve para **investigar**, e investigar é seguro de fazer em paralelo.
**Agir** já não é, e por isso fica exatamente onde deve ficar, na única conversa que
estás mesmo a acompanhar. Quando um worker descobre que há algo a fazer, ele diz isso, e
é quem delegou que faz, passando pela barreira de permissão, à tua frente.

Há ainda uma segunda razão, puramente aritmética: sem a regra "um worker não pode
delegar", uma tarefa vira oito, oito viram sessenta e quatro, e a conta chega antes da
resposta.

<div class="note"><strong>Um limite fixo de oito tarefas por chamada.</strong> O modelo já sabe deste limite, por isso reparte o trabalho em vez de ser apanhado de surpresa por ele.</div>

## Delegar em nome de outro agente

```
delegate(tasks: [...], agent: "researcher")
```

Assim, os workers correm como um agente diferente, com a persona e as ferramentas desse
agente, mas sempre despidos de tudo o que possa agir. A regra é a mesma lista de
permissões dirigida que já vale para `send_to_agent`: um agente só consegue emprestar a
identidade de outro se já tivesse autorização para lhe enviar mensagens. Uma única
autoridade a decidir o ato, nunca uma segunda mais fraca a validar por trás. As rotas
estão explicadas na página [Agentes](../agents/).

## Sem esperar pela resposta

```
delegate(tasks: [...], background: true)
```

O mesmo fan-out, mas disparado sem esperar: a chamada volta logo com uma confirmação, o
agente pode continuar a trabalhar ou simplesmente avisar-te de que já está a tratar
disso, e os resultados chegam mais tarde como uma mensagem de seguimento normal, na
mesma conversa, assim que o último worker terminar. Compensa recorrer a isto quando o
fan-out é mesmo lento (várias páginas para ler, um worker com trabalho de raciocínio a
sério pela frente); esperar uns segundos continua a ser a opção mais simples, e não
precisa de nenhuma explicação extra para quem está do outro lado. Só funciona dentro de
uma conversa real: uma execução de turno único não tem sessão nenhuma onde entregar os
resultados mais tarde.

## O que isto custa

Cada worker é uma chamada de modelo a sério, medida e faturada como qualquer outra, e
imputada ao mesmo projeto. Oito workers são oito turnos completos. É essa a troca: compra-se
de volta tempo de espera e espaço na janela de contexto, e paga-se isso em tokens. Para
uma tarefa que de outra forma nunca caberia numa única janela, nem chega a ser
propriamente uma troca.

Cada worker fica com o seu próprio trace, por isso a secção **Traces**, no
[painel](../dashboard/), mostra o que cada um fez de facto, e não apenas o que o pai
relatou sobre isso.
