#!/bin/sh
# Assistant administrateur de « Rester actif », version 6.
# Appelé par l'application (via sudo) et par launchd. Commandes :
#   start <secondes>  garde le Mac éveillé pendant cette durée ; relancé, il remplace la durée en cours
#   stop              rétablit tout de suite la veille normale
#   attendre          (launchd) attend l'heure de fin, puis rétablit la veille
#   demarrage         (launchd, au démarrage du Mac) rétablit la veille si une session a été interrompue
#   version           affiche la version, pour vérifier que l'application et l'assistant concordent
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
VERSION=6
LABEL=local.rester-actif
MOI=/usr/local/libexec/rester-actif
JOB=/var/run/$LABEL.plist
FIN=/var/run/$LABEL.fin
MOTIF=/var/run/$LABEL.motif
MARQUEUR=/var/db/$LABEL.actif
DUREE_MAX=604800   # une semaine
BATTERIE_MIN=10    # pourcentage sous lequel une session sur batterie s'arrête

# Le journal ne doit jamais faire échouer une commande.
journal() { logger -t rester-actif "$*" 2>/dev/null || :; }

echec() {
  echo "$*" >&2
  journal "erreur : $*"
  exit 1
}

# Écriture atomique d'un petit fichier lisible par l'application.
ecrire() {
  printf '%s\n' "$2" > "$1.tmp" && chmod 644 "$1.tmp" && mv -f "$1.tmp" "$1"
}

veille_desactivee() {
  pmset -g | awk '$1 == "SleepDisabled" && $2 == "1" { trouve = 1 } END { exit !trouve }'
}

batterie_faible() {
  etat=$(pmset -g batt 2>/dev/null) || return 1
  case "$etat" in *"'Battery Power'"*) ;; *) return 1 ;; esac
  pourcent=$(printf '%s\n' "$etat" | sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%.*/\1/p' | head -n 1)
  [ -n "$pourcent" ] && [ "$pourcent" -le "$BATTERIE_MIN" ]
}

compte_a_rebours_charge() {
  launchctl print "system/$LABEL" >/dev/null 2>&1
}

# Décharge le compte à rebours de launchd et attend qu'il ait vraiment disparu.
arreter_compte_a_rebours() {
  launchctl bootout "system/$LABEL" 2>/dev/null
  essais=0
  while compte_a_rebours_charge; do
    essais=$((essais + 1))
    [ "$essais" -ge 25 ] && return 1
    sleep 0.2
  done
  return 0
}

# Rétablit la veille normale. $1 : motif éventuel, que l'application affiche.
# Le motif est écrit avant la suppression de FIN, puisque l'application le lit quand FIN disparaît.
# Si macOS ne réactive pas la veille, le marqueur reste : le prochain démarrage réessaiera.
retablir() {
  if [ -n "${1:-}" ]; then ecrire "$MOTIF" "$1"; else rm -f "$MOTIF"; fi
  pmset -a disablesleep 0
  if veille_desactivee; then
    journal "erreur : macOS n'a pas réactivé la veille"
    return 1
  fi
  rm -f "$FIN" "$MARQUEUR"
}

demarrer() {
  maintenant=$(date +%s)   # heure de la demande : attendre l'arrêt de l'ancien compte à rebours ne décale pas la fin
  # Entier sans zéro initial et de six chiffres au plus : le calcul du shell reste exact.
  case "${1:-}" in ''|0*|*[!0-9]*|???????*) echec "Durée invalide : ${1:-vide}." ;; esac
  [ "$1" -le "$DUREE_MAX" ] || echec "La durée ne peut pas dépasser une semaine."
  if batterie_faible; then
    echec "Batterie à ${BATTERIE_MIN} % ou moins : branche le Mac pour le garder éveillé."
  fi
  if ! arreter_compte_a_rebours; then
    retablir
    echec "L'ancien compte à rebours ne s'arrête pas : la veille reste normale."
  fi
  fin=$(( maintenant + $1 ))
  : > "$MARQUEUR"          # posé avant la désactivation : un redémarrage sera toujours rattrapé
  ecrire "$FIN" "$fin"
  rm -f "$MOTIF"
  pmset -a disablesleep 1
  if ! veille_desactivee; then
    retablir
    echec "macOS a refusé de désactiver la veille."
  fi
  cat > "$JOB" <<FIN_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$MOI</string>
    <string>attendre</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
FIN_PLIST
  erreur=$(launchctl bootstrap system "$JOB" 2>&1)
  resultat=$?
  rm -f "$JOB"             # launchd garde la définition en mémoire : le fichier ne sert plus
  if [ "$resultat" -ne 0 ]; then
    retablir
    echec "Le compte à rebours n'a pas pu démarrer, la veille reste normale : $erreur"
  fi
  journal "veille désactivée pour $1 s (fin : $fin)"
}

# Lancé par launchd. Une prolongation ou un arrêt le tue (launchctl bootout) sans rien rétablir :
# c'est alors l'opération en cours qui s'en charge.
attendre() {
  while :; do
    fin=$(cat "$FIN" 2>/dev/null) || break
    case "$fin" in ''|0*|*[!0-9]*) break ;; esac
    reste=$(( fin - $(date +%s) ))
    [ "$reste" -le 0 ] && break
    if batterie_faible; then
      retablir batterie || exit 1
      journal "batterie à ${BATTERIE_MIN} % ou moins : veille rétablie"
      exit 0
    fi
    # Pauses de 30 s au plus, l'heure étant relue à chaque tour : la fin reste juste
    # même si le Mac a été mis en veille de force entre-temps.
    sleep $(( reste < 30 ? reste : 30 ))
  done
  retablir || exit 1
  journal "fin du compte à rebours : veille rétablie"
}

au_demarrage() {
  [ -e "$MARQUEUR" ] || exit 0
  # Démon rechargé en pleine session (réglages d'arrière-plan, par exemple) : rien à rattraper.
  compte_a_rebours_charge && exit 0
  retablir redemarrage || exit 1
  journal "session interrompue par un redémarrage : veille rétablie"
}

arreter() {
  arreter_compte_a_rebours || journal "le compte à rebours ne s'est pas arrêté à temps"
  retablir || echec "macOS n'a pas réactivé la veille. Réessaie ; si cela persiste, redémarre le Mac."
  journal "arrêt demandé : veille rétablie"
}

case "${1:-}" in
  start) demarrer "${2:-}" ;;
  stop) arreter ;;
  attendre) attendre ;;
  demarrage) au_demarrage ;;
  version) echo "$VERSION" ;;
  *) echo "Usage : start <secondes> | stop | version" >&2; exit 2 ;;
esac
