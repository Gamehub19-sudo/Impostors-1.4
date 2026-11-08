# Impostor & Inocente Online

## Instalação
1. Execute `atualizacao_supabase_parties.sql` no SQL Editor do **mesmo projeto Supabase** em que instalou o banco anterior.
2. Em Authentication → Providers, habilite **Anonymous Sign-ins**.
3. Envie `index.html` ao repositório GitHub, substituindo o anterior.
4. Em Settings → Pages, publique a branch `main` na pasta raiz.

## Como jogar
Digite um nome, clique em Jogar → Criar party, escolha o máximo de jogadores (4 a 12) e o número de impostores (1 a 3), confirme e compartilhe o código. Outros jogadores podem entrar por código ou pela lista de salas. O anfitrião inicia a partida.

## Observações
O jogo usa Supabase e precisa de internet. O sistema atual usa consultas periódicas para sincronizar ações. Para produção pública, são recomendadas medidas adicionais de moderação, prevenção de abuso e antitrapaça.
