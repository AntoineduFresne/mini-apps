#!/bin/zsh
# Retire « Relancer » : arrête le programme, puis supprime son inscription au démarrage et
# l'application. Le journal (~/Library/Logs/Relancer) est conservé.
emulate -R zsh
PATH=/usr/bin:/bin:/usr/sbin:/sbin
etiquette=local.relancer
# L'application est celle qui contient ce script. Lancé depuis le dépôt, il prend celle du
# dossier Applications.
app=${0:A:h:h:h}
if [[ ${app:t} != Relancer.app ]]; then
  app=/Applications/Relancer.app
  [[ -d $app ]] || app=$HOME/Applications/Relancer.app
fi
launchctl bootout gui/$UID/$etiquette 2>/dev/null
pkill -x Relancer 2>/dev/null
rm -f $HOME/Library/LaunchAgents/$etiquette.plist
if [[ -d $app ]]; then
  print -r -- "Relancer est arrêté et retiré du démarrage. Suppression de $app."
  rm -rf $app
else
  print -r -- "Relancer est arrêté et retiré du démarrage. L'application n'a pas été trouvée."
fi
