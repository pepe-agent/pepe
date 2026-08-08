# Notas da Versão — 0.14.0

Olá! Aqui estão as novidades e melhorias desta atualização do Pepe.

---

## ✨ Novidades

### Senha do painel agora fica protegida no arquivo de configuração

Até aqui, a senha que você configurava para o painel do Pepe era guardada em texto puro no arquivo `config.json`. Qualquer pessoa com acesso ao arquivo conseguia ler a senha diretamente. Agora ela fica criptografada (hash bcrypt), bem mais segura. Se você já tem uma senha antiga guardada em texto puro, o sistema continua aceitando, mas na próxima vez que você configurar uma nova senha, ela já vai ficar protegida.

📍 *Onde ver: `pepe dashboard password` (CLI) ou a página Configuração › Dashboard*

### Você agora digita a senha do painel sem ela aparecer na tela

Quando você executa `pepe dashboard password` no terminal, a senha agora é digitada "escondida" — aquela forma segura onde os caracteres não aparecem enquanto você digita. Antes, a senha tinha que vir como um argumento do comando (`pepe dashboard password 'minha_senha'`), o que deixava ela visível no histórico do terminal de qualquer pessoa que usasse aquela máquina. Agora é mais seguro: você digita sem ela aparecer.

📍 *Onde ver: Terminal do servidor, comando `pepe dashboard password`*

### Nova página no site com todos os comandos da CLI

Criamos uma página de referência com todos os comandos do `pepe` — agora tudo está organizado por assunto (configuração, modelos, agentes, execução, Telegram, etc.), com exemplos de uso, em português e inglês. Antes, você tinha que procurar os comandos espalhados em várias páginas da documentação.

📍 *Onde ver: Site, seção Documentação › Referência CLI*

### Painéis de agentes agora podem ser conectados a extensões específicas

Se você usa plugins (extensões) do Pepe, agora consegue dizer "este agente deve usar este plugin específico para busca de memória" ou "para busca na web" — tudo diretamente no painel, sem precisar editar o arquivo de configuração. Antes, só era possível fazer isso editando a mão.

📍 *Onde ver: Painel › Agentes › (abrir um agente) › Seção "Extension slots"*

---

## 🚀 Melhorias

### Se você roda o Pepe em um container Docker, agora recebe as instruções certas

Quando o painel mostrava um erro ou queria ensinar um comando, às vezes sugeria `mix pepe ...` — que é um comando só do desenvolvimento, não funciona dentro de um container. Isso confundia muito quem roda o Pepe de verdade em Docker. Agora as instruções são diferentes: em um container, o sistema sugere o comando que realmente funciona lá (`bin/pepe rpc`).

📍 *Onde ver: Em qualquer mensagem de erro ou instrução do painel / dashboard*

### A tela de Configuração não fica mais espremida com muitos registros

Quando havia muitas mudanças recentes na sua configuração, a lista de histórico ocupava tanto espaço que o editor de `config.json` ficava minúsculo e quase inutilizável. Agora o histórico fica em seu próprio espaço (com scroll separado), então o editor sempre fica visível e prático.

📍 *Onde ver: Painel › Configuração*

### Texto do painel fica mais direto e claro

Reescrevemos as instruções longas do painel (aquele texto que explica o que cada botão faz, o que cada opção significa) para ficar mais direto. A segurança está toda lá, só que explicada melhor e sem rodeios.

📍 *Onde ver: Em todos os formulários e seções do painel*

---

## 🔧 Correções

### Terminal não congela mais quando o prompt fica sem entrada

Se você rodava `pepe setup` ou `pepe model add` no terminal e fechava a conexão de entrada (por exemplo, fechando a aba, desligando a SSH, ou redirecionando de um arquivo que acabou), o comando ficava preso em um loop infinito, queimando 100% de CPU. Agora ele avisa e encerra direitinho.

### Comando rápidos não travam mais quando você tem plugins instalados

Se você queria rodar um comando tipo `pepe agent add ...` ou `pepe plugin route enable ...` (aqueles que mudam configuração mas não iniciam o servidor inteiro), e você tinha plugins instalados, o Pepe simplesmente quebraba. Agora funciona sem problemas.

### Nomes de slots desconhecidos são recusados

Se você digitava um nome de slot errado (um typo) no editor de agentes ou via CLI, o Pepe aceitava silenciosamente e fazia nada. Agora ele reclama e diz qual é o problema.

### Traduções do painel corrigidas

A palavra "não instalado" foi traduzida errado para português (dizia "não permitido"). Agora está correto em português europeu e português brasileiro.

---

## 🛡️ Segurança

### Atualização de dependência que fecha uma falha de segurança

Atualizamos a biblioteca `postgrex` (0.22.3 → 0.22.4) que tinha uma falha de injeção de SQL. O Pepe em si não é diretamente afetado (não usa aquela funcionalidade), mas a atualização é uma boa prática de segurança e está incluída nesta versão.

📍 *Detalhes técnicos: GHSA-3gww-3f36-2388 / CVE-2026-66838*

---

*Atualizado em 08/08/2026*
