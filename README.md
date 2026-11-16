# AI Disk Check

Aplicativo nativo para macOS que mostra quanto espaço os worktrees do Git ocupam e permite limpar builds ou remover um worktree com prévia e confirmação.

A interface agrupa worktrees por ferramenta, incluindo Codex, Claude e GitHub Copilot. Selecione um item para ver o caminho, o espaço usado, a atividade Git e a situação do pull request. O painel indica quando a origem foi inferida. A consulta de PRs usa a autenticação local do GitHub CLI.

## Compilar e abrir

Em um Mac com macOS 14 ou posterior e as ferramentas de desenvolvimento do Xcode instaladas, execute na raiz do projeto:

```sh
./scripts/package.sh
open "dist/AI Disk Check.app"
```

O script gera um aplicativo assinado localmente e um ZIP para a arquitetura do Mac usado na compilação. Para executar os testes de aceitação, use `./scripts/test.sh`.

## Licença

O projeto usa a [licença MIT](LICENSE). Os avisos de licença de [Devicon](Resources/Devicon-LICENSE.txt), [Lobe Icons](Resources/LobeIcons-LICENSE.txt) e [Octicons](Resources/Octicons-LICENSE.txt) acompanham os ícones distribuídos.
