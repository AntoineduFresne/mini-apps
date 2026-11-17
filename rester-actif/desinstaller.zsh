#!/bin/zsh
# Retire « Rester actif » : arrête la session en cours s'il y en a une (la veille normale est
# alors rétablie), puis supprime l'assistant administrateur, la règle sudo, la vérification au
# démarrage, l'application et ses réglages. Ton mot de passe est demandé une fois.
#
# Avec l'option --systeme, il s'arrête après les éléments système. L'installeur s'en sert pour
# retirer ceux de la version précédente avant de poser les nouveaux.
emulate -R zsh
PATH=/usr/bin:/bin:/usr/sbin:/sbin

desinstaller() {
  local mode=${1:-tout}
  if [[ $mode != tout && $mode != --systeme ]]; then
    print -r -- "Usage : zsh desinstaller.zsh [--systeme]"
    return 2
  fi
  if [[ $(id -u) -eq 0 ]]; then
    print -r -- "Lance ce script sans sudo : il demandera lui-même ton mot de passe."
    return 1
  fi
  # Les commandes lancées en administrateur. La veille n'est rétablie que si une session de
  # Rester actif était en cours.
  local nettoyage
  nettoyage=$(mktemp) || return 1
  cat > $nettoyage <<'FIN_DU_NETTOYAGE'
/bin/launchctl bootout system/local.rester-actif 2>/dev/null
/bin/launchctl bootout system/local.rester-actif.demarrage 2>/dev/null
if [ -e /var/db/local.rester-actif.actif ] || [ -e /var/run/local.rester-actif.fin ]; then /usr/bin/pmset -a disablesleep 0; fi
/bin/rm -f /var/run/local.rester-actif.plist /var/run/local.rester-actif.fin /var/run/local.rester-actif.fin.tmp /var/run/local.rester-actif.motif \
  /var/run/local.rester-actif.motif.tmp /var/db/local.rester-actif.actif /usr/local/libexec/rester-actif /etc/sudoers.d/rester-actif /Library/LaunchDaemons/local.rester-actif.demarrage.plist
FIN_DU_NETTOYAGE
  if [[ $mode == tout ]]; then
    print -r -- "Désinstallation (ton mot de passe est demandé une fois)…"
  fi
  if ! sudo /bin/sh $nettoyage; then
    rm -f $nettoyage
    print -r -- "La partie administrateur n'a pas pu s'exécuter (mot de passe refusé ?) : rien n'a été retiré."
    return 1
  fi
  rm -f $nettoyage
  if [[ $mode == --systeme ]]; then
    return 0
  fi
  sudo /bin/rmdir /usr/local/libexec 2>/dev/null
  sudo -k
  pkill -x ResterActif 2>/dev/null
  rm -rf "/Applications/Rester actif.app" "$HOME/Applications/Rester actif.app"
  defaults delete local.rester-actif.app 2>/dev/null
  rm -rf "$HOME/Library/Saved Application State/local.rester-actif.app.savedState"
  print -r -- "Rester actif est désinstallé. Retire aussi, à la main, son bouton du Centre de contrôle s'il existe."
  return 0
}
desinstaller "$@"
