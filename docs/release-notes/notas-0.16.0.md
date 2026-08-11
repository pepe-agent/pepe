# Notas da Versão — 0.16.0

Uma versão pequena, focada em **diagnóstico no Telegram** e **visibilidade no dashboard**.

---

## ✨ Novidades

### Log de diagnóstico quando um clique de botão é recusado no Telegram

Agora quando alguém clica num botão de permissão (ou de escolha de modelo) no Telegram e a ação é recusada, o Pepe registra tudo — quem era, qual era o ID do usuário, o que o Telegram disse sobre a identidade. Antes nada era anotado.

Isso ajuda a investigar um problema bem específico: quando uma pessoa consegue conversar normalmente num grupo, mas toda vez que tenta clicar num botão de permissão aparece "não autorizado". A culpada costuma ser uma identidade "enviar como" (um admin anônimo do grupo, ou um canal vinculado ao grupo) que muda o ID da pessoa só naquele clique, sem que nada na configuração esteja errado.

📍 *Onde ver: nos logs do Pepe; procure por "[telegram] denied"*

### Versão do Pepe aparece no dashboard

O menu lateral do dashboard (onde diz "Painel local") agora mostra qual versão do Pepe está rodando naquele momento. Antes a única forma era abrir o terminal e rodar `mix pepe version`.

📍 *Onde ver: Dashboard › canto inferior esquerdo, ao lado de "Painel local"*

---

*Atualizado em 11/08/2026*
