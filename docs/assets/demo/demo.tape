# Records the README demo inside the demo container.
Output "/out/demo.gif"

Set Shell zsh
Set FontFamily "Maple Mono NF CN"
Set FontSize 20
Set Width 1280
Set Height 720
Set Padding 28
Set Theme "Molokai"
Set WindowBar Colorful
Set TypingSpeed 55ms
Set CursorBlink false

Hide
# VHS starts zsh without startup files; load the managed configuration.
Type "exec zsh -l" Enter
Sleep 3s
Type "print -s 'git log --oneline -1'; cd ~/.local/share/chezmoi; clear" Enter
Sleep 1s
Show

Type "mise current" Sleep 400ms Enter
Sleep 2s

Type 'bash "$(chezmoi source-path)/bootstrap/scripts/check.sh"' Sleep 400ms Enter
Sleep 5s

Type "clear" Enter
Type "git lo"
Sleep 1200ms
Right
Sleep 600ms Enter
Sleep 1500ms

Type "rg -n 'ZSH_THEME' dot_zshrc.tmpl" Sleep 400ms Enter
Sleep 2s

Type "bat -r 1:8 bootstrap/manifests/shell/oh-my-zsh-plugins.txt" Sleep 400ms Enter
Sleep 3500ms
