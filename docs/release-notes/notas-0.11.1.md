# Notas da Versão — 0.11.1

Uma versão com um assunto só: **o painel agora funciona no celular**. Nenhuma tela nova, nenhum recurso novo — as mesmas páginas de sempre, agora legíveis numa largura em que antes não eram.

---

## 🐛 Correções

### O painel dá para usar do celular

O painel tinha sido feito para uma janela larga. O menu lateral ocupava 256 pixels e não saía da tela em largura nenhuma, então num celular de 390 pixels sobravam 134 para o conteúdo: cada seção lia uma palavra por linha, os botões saíam pela borda e a página rolava para o lado.

Agora, abaixo de 768 pixels, o menu vira uma gaveta que desliza por cima do conteúdo. Você abre no botão de três traços que fica ao lado do título de cada seção, e fecha tocando fora dele, apertando Esc, ou simplesmente escolhendo para onde ir. Junto com isso:

- Os botões de ação de cada seção descem para baixo do título em vez de disputar espaço com ele.
- Formulários de duas colunas viram uma só.
- As margens encolhem, para não gastar um sexto da tela com espaço vazio nas laterais.
- Os botões que só apareciam ao passar o mouse (parar e apagar uma conversa) ficam sempre visíveis no toque, onde não existe passar o mouse.

De 768 pixels para cima, nada mudou: o painel no computador é exatamente o que era.

📍 *Onde ver: qualquer página do painel, num celular*

### O Chat mostra uma tela por vez no celular

A lista de conversas e a conversa aberta ficavam sempre lado a lado. Num celular isso significava duas colunas espremidas; num tablet, uma terceira coluna que deixava a conversa com uns 190 pixels de largura.

Agora as duas só aparecem juntas a partir de 1024 pixels. Abaixo disso é uma tela por vez: a lista, e ao escolher uma conversa, a conversa inteira com um botão de voltar no canto.

📍 *Onde ver: painel → Chat*

### O campo de mensagem não some mais atrás da barra do navegador

O painel media a altura pela tela cheia do navegador, sem contar que a barra de endereço do celular aparece e some conforme você rola. O resultado é que o campo de escrever mensagem, e os botões no fim de um formulário longo, ficavam por baixo dela.

A medida agora acompanha a área realmente visível. A tela de login, que tinha largura fixa, também deixou de vazar em telas estreitas.

---

## 🔧 Por baixo do capô

- A gaveta do menu é feita só com CSS: um campo de marcação escondido e rótulos que apontam para ele. Nenhuma das 19 seções do painel precisou ganhar código próprio para ter um menu funcionando, e a gaveta não depende de o servidor responder para abrir.
- As 19 seções foram conferidas em 360, 390, 768, 1024 e 1440 pixels de largura, e nenhuma delas rola para o lado. As tabelas largas (uso, execuções) continuam rolando dentro da própria moldura, como já faziam.
