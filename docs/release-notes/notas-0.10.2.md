# Notas da Versão — 0.10.2

Olá! Esta é uma release pequena e focada: uma correção de um bug real descoberto ao usar `browser` em Docker.

---

## 🐛 Correções

### Browser agora funciona em Docker e containers Linux
A ferramenta `browser` lançada na versão anterior tinha um problema sério em ambientes containerizados (Docker, Kubernetes, etc.): travava completamente na tentativa de iniciar o Chrome. A causa: o Chrome procura um "barramento D-Bus" que não existe dentro de um container — tentava conectar repetidamente, expirava o timeout, e o browser nunca abria.

Isso afetava qualquer um rodando o Pepe em Docker, incluindo a imagem oficial. Agora funciona: tratamos o problema da mesma forma que CI headless faz (redirecionamos a busca D-Bus pra um lugar que falha rápido, sem repetir), e aumentamos um pouco o timeout pra arranques lentos em máquinas carregadas.

📍 *Onde usar: automaticamente, se você estava usando Docker*

### Website: correção de segurança XSS
A dependência `astro` foi atualizada para corrigir três falhas de XSS refletido na ferramenta de build do site de documentação (duas delas com CVE publicado). Não afeta o app Pepe em si, apenas o tooling que constrói as páginas de ajuda.

---

*Atualizado em 22/07/2026*
