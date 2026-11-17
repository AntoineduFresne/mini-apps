#!/bin/zsh
#
# Installe « Relancer », le petit programme qui relance l'application au premier plan avec
# Contrôle + Option + Commande + R, dans toutes les applications.
#
# À lancer dans le Terminal :   zsh installer.zsh
#
# Les fichiers rangés à côté de ce script :
#   Relancer.m                 le code source du programme
#   Info.plist, AppIcon.icns   la fiche et l'icône de l'application
#   local.relancer.plist       l'inscription au démarrage de la session
#   essai/                     une petite app d'essai, qui imite les apps difficiles à relancer
#   desinstaller.zsh           retire tout ce que ce script installe
#
# Ce que fait ce script, dans l'ordre :
#   1. il compile le programme ;
#   2. il l'essaie huit fois, sans toucher à tes applications : sur la Calculatrice, puis sur
#      l'app d'essai, qui imite tour à tour VS Code, WhatsApp, Mail, une app qui affiche un
#      dialogue d'enregistrement et une app qui tarde à répondre ;
#   3. si aucun essai n'échoue et qu'au moins un réussit, il range le programme dans
#      /Applications/Relancer.app, à la place de la version précédente, avec son désinstalleur ;
#   4. il l'inscrit au démarrage de ta session (~/Library/LaunchAgents/local.relancer.plist)
#      et le démarre tout de suite ;
#   5. il enregistre tout ce qui s'est passé dans
#      ~/Library/Logs/Relancer/rapport-installation.txt, et copie ce compte rendu dans le
#      presse-papiers pour que tu puisses le coller ailleurs.
#
# Une fois installé, le programme démarre à l'ouverture de la session, et macOS le redémarre
# s'il s'arrête de façon anormale. Le journal de chaque relance se trouve dans
# ~/Library/Logs/Relancer/Relancer.log.
#
# Il ne demande pas ton mot de passe et ne touche à rien d'autre. Si une étape échoue, il
# s'arrête sans rien installer. Tu peux le relancer autant de fois que tu veux.
#
# Pour tout retirer :   zsh desinstaller.zsh
#

emulate -R zsh                       # options de zsh d'origine, quels que soient tes réglages
zmodload zsh/datetime                # pour mesurer la durée des essais
PATH=/usr/bin:/bin:/usr/sbin:/sbin

dossier=${0:A:h}                     # dossier de ce script : le code source et les autres fichiers y sont
etiquette=local.relancer
agent=$HOME/Library/LaunchAgents/$etiquette.plist
journal=$HOME/Library/Logs/Relancer/Relancer.log
rapport=$HOME/Library/Logs/Relancer/rapport-installation.txt

# ---------------------------------------------------------------------------------------
# Outils
# ---------------------------------------------------------------------------------------

# pid_de <nom du processus> : affiche le premier numéro de processus qui porte ce nom.
pid_de() {
  pgrep -x $1 2>/dev/null | head -1
}

# essayer <programme> <nom du processus> <app à ouvrir> <identifiant> <arrêt attendu> [mode] [question]
# Ouvre l'app en arrière-plan, la fait relancer par le programme, vérifie qu'elle a bien été
# fermée puis rouverte, et la referme. « Arrêt attendu » dit si le programme doit avoir arrêté
# lui-même le processus de l'app (oui), s'il ne doit surtout pas l'avoir fait (non), s'il ne
# devrait pas l'avoir fait mais que l'essai n'est qu'une imitation approximative (prudent), ou
# si cela n'a pas d'importance (libre). « Mode » est le comportement que l'app d'essai imite.
# Avec le mot « question », le programme simule en plus un second appui : sa fenêtre « forcer à
# quitter » doit s'afficher, puis se refermer toute seule quand l'app se ferme.
# Renvoie 0 si l'essai réussit, 1 s'il échoue, 2 s'il n'a pas pu avoir lieu, 3 si la relance
# a réussi mais sans l'arrêt attendu (elle a donc été lente), 4 si elle a réussi avec un
# arrêt que l'essai « prudent » n'attendait pas, et 5 si elle a réussi sans que la fenêtre
# « forcer à quitter » se soit affichée puis refermée comme prévu.
essayer() {
  local programme=$1 nom=$2 cible=$3 identifiant=$4 attendu=$5 mode=${6:-} question=${7:-}
  local avant="" apres="" code=0 arret=non debut=0 duree=0 lisible=""
  if [[ -n $mode ]]; then
    open -g -n $cible --args $mode
  elif [[ $nom == RelancerEssai ]]; then
    open -g -n $cible
  else
    open -g $cible
  fi
  repeat 50; do
    avant=$(pid_de $nom)
    [[ -n $avant ]] && break
    sleep 0.1
  done
  if [[ -z $avant ]]; then
    print -r -- "L'app ne s'est pas ouverte : cet essai n'a pas pu avoir lieu."
    return 2
  fi
  sleep 1.2
  debut=$EPOCHREALTIME
  $programme --essai $avant $question | tee $sortie_essai
  code=${pipestatus[1]}
  duree=$(( EPOCHREALTIME - debut ))
  lisible=$(printf '%.1f' $duree)
  repeat 30; do
    apres=$(pid_de $nom)
    [[ -n $apres && $apres != $avant ]] && break
    sleep 0.1
  done
  grep -q "je l'arrête" $sortie_essai 2>/dev/null && arret=oui
  # Referme proprement l'app ouverte pour l'essai, et attend qu'elle ait disparu.
  if [[ -n $apres ]]; then
    osascript -e "tell application id \"$identifiant\" to quit" >/dev/null 2>&1
    sleep 0.5
    kill $apres 2>/dev/null
  fi
  if [[ $nom == RelancerEssai ]]; then
    pkill -x RelancerEssai 2>/dev/null
    repeat 30; do
      [[ -z $(pid_de RelancerEssai) ]] && break
      sleep 0.1
    done
  fi
  if (( code != 0 )) || [[ -z $apres || $apres == $avant ]]; then
    print -r -- "ÉCHOUÉ : code $code, processus avant $avant, après ${apres:-aucun}."
    return 1
  fi
  if [[ $attendu == non && $arret == oui ]]; then
    print -r -- "ÉCHOUÉ : le programme a arrêté une app qui montrait encore une fenêtre."
    return 1
  fi
  if [[ $attendu == prudent && $arret == oui ]]; then
    print -r -- "À NOTER ($lisible s) : le programme a arrêté l'app d'essai sans voir sa fenêtre placée hors de l'écran."
    return 4
  fi
  if [[ $attendu == oui && $arret == non ]]; then
    print -r -- "RELANCE LENTE ($lisible s) : l'app a été rouverte, mais le programme a attendu qu'elle se ferme d'elle-même."
    grep "je ne l'arrête pas" $sortie_essai 2>/dev/null | tail -1
    return 3
  fi
  if [[ -n $question ]]; then
    if grep -q "je propose de la forcer" $sortie_essai 2>/dev/null \
       && grep -q "n'est pas forcée" $sortie_essai 2>/dev/null; then
      print -r -- "RÉUSSI en $lisible s : la fenêtre « forcer à quitter » s'est affichée, puis refermée toute seule, et l'app a été rouverte (processus $avant, puis $apres)."
      return 0
    fi
    print -r -- "À NOTER ($lisible s) : l'app a été rouverte, mais la fenêtre « forcer à quitter » ne s'est pas affichée puis refermée comme prévu."
    return 5
  fi
  print -r -- "RÉUSSI en $lisible s : l'app a été fermée puis rouverte (processus $avant, puis $apres)."
  return 0
}

# ---------------------------------------------------------------------------------------
# L'installation
# ---------------------------------------------------------------------------------------

installer() {
  local version
  version=$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' $dossier/Info.plist 2>/dev/null)
  print -r -- "Installation de Relancer $version, le $(date '+%Y-%m-%d à %H:%M:%S')"
  print -r -- "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
  print

  local app=/Applications/Relancer.app
  [[ -w /Applications ]] || app=$HOME/Applications/Relancer.app
  local travail
  travail=$(mktemp -d /tmp/relancer.XXXXXX)
  if [[ -z $travail || ! -d $travail ]]; then
    print -r -- "ÉCHEC : impossible de créer un dossier temporaire. Rien n'a été modifié."
    return 1
  fi

  print -r -- "== 1. Compilation =="
  local fichier
  for fichier in Relancer.m Info.plist AppIcon.icns local.relancer.plist desinstaller.zsh \
                 essai/RelancerEssai.m essai/Info.plist; do
    if [[ ! -f $dossier/$fichier ]]; then
      print -r -- "ÉCHEC : le fichier $fichier manque à côté de ce script. Rien n'a été installé ni modifié."
      rm -rf $travail
      return 1
    fi
  done
  if ! clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -framework Cocoa -framework Carbon \
       -o $travail/Relancer $dossier/Relancer.m; then
    print
    print -r -- "ÉCHEC : la compilation n'a pas abouti. Rien n'a été installé ni modifié."
    rm -rf $travail
    return 1
  fi
  print -r -- "Le programme est compilé."
  local app_essai=""
  if clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework Cocoa \
     -o $travail/RelancerEssai $dossier/essai/RelancerEssai.m; then
    app_essai=$travail/RelancerEssai.app
    mkdir -p $app_essai/Contents/MacOS
    mv $travail/RelancerEssai $app_essai/Contents/MacOS/RelancerEssai
    cat $dossier/essai/Info.plist > $app_essai/Contents/Info.plist
    codesign --force --sign - $app_essai >/dev/null 2>&1
  else
    print -r -- "L'app d'essai n'a pas pu être compilée : les essais 2 à 8 seront sautés."
  fi
  print

  local nouvelle=$travail/Relancer.app
  mkdir -p $nouvelle/Contents/MacOS $nouvelle/Contents/Resources
  cp $travail/Relancer $nouvelle/Contents/MacOS/Relancer
  # Les fichiers sont recopiés avec « cat », et non « cp », pour ne pas emporter les marques que
  # macOS pose sur un fichier téléchargé.
  cat $dossier/Info.plist > $nouvelle/Contents/Info.plist
  cat $dossier/AppIcon.icns > $nouvelle/Contents/Resources/AppIcon.icns
  cat $dossier/desinstaller.zsh > $nouvelle/Contents/Resources/desinstaller.zsh
  if ! codesign --force --sign - $nouvelle 2>&1; then
    print -r -- "(La signature locale n'a pas pu être posée. Ce n'est pas bloquant.)"
  fi
  local programme=$nouvelle/Contents/MacOS/Relancer
  local echecs=0 reussis=0 lents=0 doutes=0 questions=0 resultat=0
  local sortie_essai=$travail/sortie-essai.txt

  # compter <résultat de l'essai>
  compter() {
    (( $1 == 0 )) && (( reussis += 1 ))
    (( $1 == 1 )) && (( echecs += 1 ))
    (( $1 == 3 )) && (( reussis += 1, lents += 1 ))
    (( $1 == 4 )) && (( reussis += 1, doutes += 1 ))
    (( $1 == 5 )) && (( reussis += 1, questions += 1 ))
    print
  }

  print -r -- "== 2. Essais (une quarantaine de secondes : ne change pas de bureau pendant ce temps) =="
  print
  print -r -- "Essai 1 sur 8 : la Calculatrice, app Mac classique"
  if [[ -n $(pid_de Calculator) ]]; then
    print -r -- "La Calculatrice est déjà ouverte : je n'y touche pas, cet essai est sauté."
    print
  elif [[ ! -d /System/Applications/Calculator.app ]]; then
    print -r -- "La Calculatrice est introuvable : cet essai est sauté."
    print
  else
    essayer $programme Calculator /System/Applications/Calculator.app com.apple.calculator libre
    compter $?
  fi

  if [[ -z $app_essai ]]; then
    print -r -- "Essais 2 à 8 sautés : l'app d'essai n'a pas pu être compilée."
    print
  else
    pkill -x RelancerEssai 2>/dev/null
    print -r -- "Essai 2 sur 8 : une app qui répond « annulé » puis se ferme, comme VS Code"
    essayer $programme RelancerEssai $app_essai local.relancer.essai libre
    compter $?
    print -r -- "Essai 3 sur 8 : une app qui se retire du Dock mais continue de tourner, comme WhatsApp"
    essayer $programme RelancerEssai $app_essai local.relancer.essai oui retrait
    compter $?
    print -r -- "Essai 4 sur 8 : une app qui ferme ses fenêtres mais continue de tourner, comme Mail"
    essayer $programme RelancerEssai $app_essai local.relancer.essai oui fenetres
    compter $?
    print -r -- "Essai 5 sur 8 : la même, dont les fenêtres sont seulement retirées de l'écran"
    essayer $programme RelancerEssai $app_essai local.relancer.essai oui gardees
    compter $?
    print -r -- "Essai 6 sur 8 : une app qui garde un dialogue à l'écran (elle ne doit pas être arrêtée)"
    essayer $programme RelancerEssai $app_essai local.relancer.essai non dialogue
    compter $?
    print -r -- "Essai 7 sur 8 : une app dont le dialogue est hors de l'écran (elle ne doit pas être arrêtée)"
    essayer $programme RelancerEssai $app_essai local.relancer.essai prudent cache
    compter $?
    print -r -- "Essai 8 sur 8 : un second appui sur une app qui tarde à répondre (une fenêtre de Relancer s'affiche un instant : n'y touche pas)"
    essayer $programme RelancerEssai $app_essai local.relancer.essai non question question
    compter $?
  fi

  if (( echecs > 0 )); then
    print -r -- "ÉCHEC : au moins un essai a échoué. Par prudence, rien n'a été installé ni modifié."
    print -r -- "La version déjà installée, s'il y en a une, continue de fonctionner comme avant."
    rm -rf $travail
    return 1
  fi
  if (( reussis == 0 )); then
    print -r -- "ÉCHEC : aucun essai n'a pu avoir lieu, donc rien n'a été vérifié. Par prudence, rien n'a été installé ni modifié."
    print -r -- "Ferme la Calculatrice si elle est ouverte, puis relance cette commande."
    rm -rf $travail
    return 1
  fi
  if (( lents > 0 )); then
    print -r -- "REMARQUE : certains essais ($lents) ont abouti sans l'accélération prévue. Le programme est"
    print -r -- "installé quand même : il relance bien les apps, mais il restera lent avec celles qui traînent."
    print -r -- "Si tu as changé de bureau pendant les essais, relance simplement cette commande."
    print
  fi
  if (( doutes > 0 )); then
    print -r -- "REMARQUE : le programme n'a pas vu une fenêtre que l'app d'essai gardait hors de l'écran. Il est"
    print -r -- "installé quand même. Seul cas concerné : une app qui t'attend avec un dialogue ouvert sur un"
    print -r -- "autre bureau que celui que tu regardes."
    print
  fi
  if (( questions > 0 )); then
    print -r -- "REMARQUE : la fenêtre « forcer à quitter », celle qui apparaît après un second appui sur une"
    print -r -- "app qui tarde à répondre, ne s'est pas comportée comme prévu pendant l'essai. Le programme est"
    print -r -- "installé quand même : les relances fonctionnent, seule cette fenêtre est en cause."
    print
  fi

  print -r -- "== 3. Installation dans $app =="
  launchctl bootout gui/$UID/$etiquette 2>/dev/null
  repeat 25; do
    launchctl print gui/$UID/$etiquette >/dev/null 2>&1 || break
    sleep 0.2
  done
  pkill -x Relancer 2>/dev/null
  mkdir -p ${app:h} $HOME/Library/LaunchAgents ${journal:h}
  if [[ -e $app ]]; then
    rm -rf $app
    if [[ -e $app ]]; then
      print -r -- "ÉCHEC : macOS n'a pas laissé remplacer l'ancienne version ($app)."
      print -r -- "Mets cette application à la corbeille depuis le Finder, puis relance cette commande."
      [[ -f $agent ]] && launchctl bootstrap gui/$UID $agent 2>/dev/null
      rm -rf $travail
      return 1
    fi
  fi
  if ! mv $nouvelle $app; then
    print -r -- "ÉCHEC : impossible d'écrire $app."
    rm -rf $travail
    return 1
  fi
  rm -rf $travail
  print -r -- "Le programme est en place."
  print

  print -r -- "== 4. Démarrage =="
  local lignes_avant=0
  [[ -f $journal ]] && lignes_avant=$(wc -l < $journal)
  sed "s|@PROGRAMME@|$app/Contents/MacOS/Relancer|" $dossier/local.relancer.plist > $agent
  launchctl enable gui/$UID/$etiquette 2>/dev/null
  if ! launchctl bootstrap gui/$UID $agent; then
    print -r -- "ÉCHEC : macOS a refusé d'inscrire le programme au démarrage (launchctl bootstrap)."
    print -r -- "Cause possible : « Relancer » est désactivé dans Réglages Système > Général >"
    print -r -- "Ouverture et extensions, section des éléments autorisés en arrière-plan. Active-le, puis"
    print -r -- "relance cette commande."
    return 1
  fi
  local pret=""
  repeat 40; do
    if [[ -f $journal ]]; then
      pret=$(tail -n +$(( lignes_avant + 1 )) $journal | grep -m 1 -E 'prêt :|impossible d.enregistrer|tourne déjà')
      [[ -n $pret ]] && break
    fi
    sleep 0.25
  done
  if [[ $pret == *"prêt :"* ]]; then
    print -r -- "Le programme tourne (processus $(pid_de Relancer))."
    print -r -- "Son journal dit : ${pret#*  }"
    print
    print -r -- "INSTALLATION RÉUSSIE."
    print -r -- "Contrôle + Option + Commande + R relance maintenant l'application au premier plan."
    print
    print -r -- "macOS affiche peut-être une notification qui signale un nouvel élément en arrière-plan,"
    print -r -- "nommé Relancer : c'est ce programme, qui démarre désormais à l'ouverture de ta session."
    print -r -- "Journal de chaque relance : $journal"
    print -r -- "Pour réinstaller ou mettre à jour : zsh $dossier/installer.zsh"
    print -r -- "Pour tout retirer : zsh $dossier/desinstaller.zsh"
    return 0
  fi
  print -r -- "ÉCHEC : le programme est installé, mais il n'a pas confirmé son démarrage."
  [[ -n $pret ]] && print -r -- "Son journal dit : ${pret#*  }"
  print -r -- "État vu par macOS :"
  launchctl print gui/$UID/$etiquette 2>&1 | grep -E 'state =|pid =|last exit code' | head -5
  # Un programme qui ne démarre pas correctement ne doit pas rester inscrit au démarrage.
  launchctl bootout gui/$UID/$etiquette 2>/dev/null
  pkill -x Relancer 2>/dev/null
  rm -f $agent
  print -r -- "Par prudence, il est arrêté et retiré du démarrage. L'application reste dans $app, sans effet."
  return 1
}

mkdir -p ${rapport:h} 2>/dev/null
installer 2>&1 | tee $rapport
code=${pipestatus[1]}
print
print -r -- "Ce compte rendu est enregistré dans $rapport"
if [[ -s $rapport ]] && pbcopy < $rapport 2>/dev/null; then
  print -r -- "Il est aussi copié dans le presse-papiers : tu peux le coller tel quel dans la conversation."
fi
exit $code
