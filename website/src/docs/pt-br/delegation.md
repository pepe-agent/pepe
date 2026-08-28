---
title: Delegação (fan-out)
description: A tool delegate quebra um trabalho amplo em workers paralelos e descartáveis, cada um com sua própria janela de contexto nova, então o conjunto demora o tempo da parte mais lenta, não a soma de todas.
---

"Compare estes oito concorrentes" não é uma tarefa só, são oito, e resolver isso numa
única conversa custa caro de dois jeitos: demora oito vezes mais, e cada página lida sobre
o concorrente um segue ocupando a janela de contexto enquanto o modelo já está lendo sobre
o concorrente oito. A janela enche de material que ninguém vai revisitar, e a resposta
final piora à medida que isso acontece.

A tool `delegate` resolve isso entregando as partes a workers descartáveis, todos de uma
vez:

```
você › compare as páginas de preços da stripe, da adyen e da mollie

agente › delegate(tasks: [
           "Leia stripe.com/pricing e informe a taxa de cartão e qualquer mínimo mensal.",
           "Leia adyen.com/pricing e informe a taxa de cartão e qualquer mínimo mensal.",
           "Leia mollie.com/pricing e informe a taxa de cartão e qualquer mínimo mensal."
         ])
```

Cada worker roda numa execução própria, com sua janela de contexto e seu trace. Ele lê o
que precisa, responde à pergunta que recebeu, e some. Quem chamou recebe três respostas e
nunca vê as três transcrições completas, então o trabalho passa a caber numa janela onde
antes não caberia. E como os workers ficam esperando a rede ao mesmo tempo, o conjunto
inteiro demora só o tempo do mais lento entre eles, não a soma de todos.

## Dando a tool a um agente

Concede-se o `delegate` do jeito de sempre, dentro da lista de tools:

```bash
pepe agent add lead --model openrouter --tools fetch_url,read_file,delegate
```

## Um worker lê, mas não age

Um worker herda só as tools que não pedem permissão nenhuma: `read_file`, `list_dir`,
`fetch_url`, `web_search` e afins. Tudo que escreve, executa, instala ou apaga é retirado
antes mesmo de ele começar, e um worker não pode, por sua vez, delegar mais nada.

Isso não é uma limitação de passagem, esperando para ser removida algum dia. Três workers
rodando ao mesmo tempo seriam três workers querendo fazer três perguntas de permissão ao
mesmo tempo, e *posso rodar isso?* não é pergunta para se repetir em triplicata. Mais que
isso: o fan-out serve para **descobrir** coisas, e descobrir é seguro de fazer em
paralelo. **Agir** já não é, e continua acontecendo onde deveria, dentro da única conversa
que você realmente está acompanhando. Um worker que percebe que algo precisa ser feito
avisa sobre isso, e quem faz de fato é o agente principal, passando pela barreira de
permissão, na sua frente.

Há também uma proteção puramente aritmética: sem a regra de "um worker não delega", uma
tarefa vira oito, depois vira sessenta e quatro, e a conta chega antes da resposta.

<div class="note"><strong>Um teto fixo de oito tarefas por chamada.</strong> O modelo sabe desse limite de antemão, então ele mesmo divide o trabalho em vez de ser pego de surpresa por ele.</div>

## Delegando como outro agente

```
delegate(tasks: [...], agent: "researcher")
```

Assim, os workers rodam como um agente diferente, com a persona e as tools desse agente,
ainda sem nada que permita agir. Vale a mesma lista de permissão dirigida do
`send_to_agent`: um agente só pode assumir a identidade de outro se já tivesse autorização
para mandar mensagem a ele. Uma única autoridade cobre o ato, não existe uma segunda porta
mais fraca. As rotas estão explicadas na página [Agentes](../agents/).

## Sem esperar pela resposta

```
delegate(tasks: [...], background: true)
```

O mesmo fan-out, mas disparado sem espera: a chamada retorna na hora, com uma confirmação
de recebimento, o agente segue trabalhando ou já avisa que está cuidando disso, e os
resultados chegam depois como uma mensagem comum de acompanhamento, na mesma conversa,
assim que todos os workers terminarem. Vale a pena usar quando o fan-out é realmente
demorado (várias páginas para ler, um worker com raciocínio pesado pela frente). Esperar
alguns segundos ainda é mais simples e dispensa qualquer explicação ao usuário. Isso só
funciona dentro de uma conversa de verdade, uma execução one-shot não tem sessão para
receber os resultados depois.

## O custo disso

Cada worker é uma chamada de modelo de verdade, medida e cobrada como qualquer outra, no
mesmo projeto. Oito workers equivalem a oito turnos. É essa a troca: você recupera tempo
de relógio e espaço na janela de contexto, e paga por isso em tokens. Para uma tarefa que
nunca caberia numa única janela, isso nem chega a ser uma troca de verdade.

Cada worker ganha seu próprio trace, então a aba **Traces** do [dashboard](../dashboard/)
mostra o que cada um efetivamente fez, e não apenas o resumo que o agente principal deu
sobre isso.
