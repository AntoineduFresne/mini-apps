#!/bin/zsh
#
# Installe « Rester actif », la petite application qui garde le Mac éveillé, même capot fermé,
# pendant une durée choisie.
#
# À lancer dans le Terminal :   zsh installer.zsh
#
# Les fichiers rangés à côté de ce script :
#   ResterActif.swift                    le code source de l'application
#   assistant.sh                         l'assistant administrateur, le seul à changer la veille
#   local.rester-actif.demarrage.plist   la vérification faite au démarrage du Mac
#   Info.plist, AppIcon.icns             la fiche et l'icône de l'application
#   desinstaller.zsh                     retire tout ce que ce script installe
#
# Ce que fait ce script, dans l'ordre :
#   1. il vérifie que macOS est en version 14 ou plus récente et que les outils de
#      développement d'Apple sont installés, puis il compile l'application. Jusque-là, rien
#      n'est modifié sur le Mac : si une vérification ou la compilation échoue, il s'arrête là ;
#   2. il demande ton mot de passe une seule fois, arrête la session en cours s'il y en a une
#      (la veille normale est alors rétablie), retire les éléments système de la version
#      précédente, puis installe ceux de cette version :
#        /usr/local/libexec/rester-actif      l'assistant administrateur (assistant.sh)
#        /etc/sudoers.d/rester-actif          la règle qui laisse l'application l'appeler sans mot de passe
#        /Library/LaunchDaemons/local.rester-actif.demarrage.plist
#   3. il range l'application dans /Applications/Rester actif.app, à la place de la version
#      précédente, avec son désinstalleur ;
#   4. il ouvre l'application.
#
# Tu peux le relancer autant de fois que tu veux.
#
# Pour tout retirer :   zsh desinstaller.zsh
#

emulate -R zsh                       # options de zsh d'origine, quels que soient tes réglages
setopt err_exit no_unset pipe_fail   # le script s'arrête à la première commande qui échoue
PATH=/usr/bin:/bin:/usr/sbin:/sbin

if (( $# > 0 )); then
  print -r -- "Ce script ne prend aucune option. Pour tout retirer : zsh desinstaller.zsh"
  exit 2
fi
if [[ $(id -u) -eq 0 ]]; then
  print -r -- "Lance ce script sans sudo : il demandera lui-même ton mot de passe."
  exit 1
fi

dossier=${0:A:h}                     # dossier de ce script : le code source et les autres fichiers y sont
ASSISTANT=/usr/local/libexec/rester-actif
REGLE=/etc/sudoers.d/rester-actif
DEMON=/Library/LaunchDaemons/local.rester-actif.demarrage.plist
NOM_APP="Rester actif.app"

# ---------------------------------------------------------------------------------------
# 1. Vérifications et préparation : rien n'est encore modifié sur le Mac.
# ---------------------------------------------------------------------------------------

VERSION_MACOS=$(sw_vers -productVersion)
if [[ ${VERSION_MACOS%%.*} -lt 14 ]]; then
  print -r -- "Rester actif demande macOS 14 ou plus récent (ce Mac a macOS $VERSION_MACOS)."
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  print -r -- "Les outils de développement d'Apple manquent : lance « xcode-select --install », puis relance ce script."
  exit 1
fi
for fichier in ResterActif.swift assistant.sh local.rester-actif.demarrage.plist Info.plist AppIcon.icns desinstaller.zsh; do
  if [[ ! -f $dossier/$fichier ]]; then
    print -r -- "Le fichier $fichier manque à côté de ce script. Rien n'a été modifié."
    exit 1
  fi
done
# La version de l'assistant est lue dans son fichier : l'application vérifie la même à son ouverture.
VERSION_ASSISTANT=$(sed -n 's/^VERSION=//p' "$dossier/assistant.sh")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Les fichiers sont recopiés avec « cat », et non « cp », pour ne pas emporter les marques que
# macOS pose sur un fichier téléchargé.
cat "$dossier/assistant.sh" > "$TMP/rester-actif"
cat "$dossier/local.rester-actif.demarrage.plist" > "$TMP/demarrage.plist"
print -r -- "$(id -un) ALL=(root) NOPASSWD: $ASSISTANT" > "$TMP/regle"
/usr/sbin/visudo -cf "$TMP/regle" >/dev/null

print -r -- "Compilation en cours, cela prend quelques secondes…"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" "$dossier/ResterActif.swift" -o "$TMP/ResterActif"

# ---------------------------------------------------------------------------------------
# 2. Partie système : ton mot de passe est demandé une seule fois.
# ---------------------------------------------------------------------------------------

print -r -- "Installation des éléments système (ton mot de passe est demandé une fois)…"
zsh "$dossier/desinstaller.zsh" --systeme
sudo /usr/bin/install -d -o root -g wheel -m 755 /usr/local/libexec
sudo /usr/bin/install -o root -g wheel -m 755 "$TMP/rester-actif" "$ASSISTANT"
sudo /usr/bin/install -o root -g wheel -m 440 "$TMP/regle" "$REGLE"
sudo /usr/bin/install -o root -g wheel -m 644 "$TMP/demarrage.plist" "$DEMON"
if ! ERREUR_DEMON=$(sudo /bin/launchctl bootstrap system "$DEMON" 2>&1); then
  print -r -- "Attention : la vérification au démarrage n'a pas pu être activée ($ERREUR_DEMON)."
  print -r -- "Vérifie dans Réglages Système que « rester-actif » est autorisé à s'exécuter en arrière-plan, puis relance ce script."
fi
sudo -k
if [[ "$(sudo -n "$ASSISTANT" version 2>/dev/null)" != "$VERSION_ASSISTANT" ]]; then
  print -r -- "L'autorisation ne fonctionne pas : /etc/sudoers doit contenir la ligne « #includedir /private/etc/sudoers.d »."
  exit 1
fi

# ---------------------------------------------------------------------------------------
# 3. Application.
# ---------------------------------------------------------------------------------------

pkill -x ResterActif 2>/dev/null || true
rm -rf "/Applications/$NOM_APP" "$HOME/Applications/$NOM_APP"
if [[ -w /Applications ]]; then DOSSIER=/Applications; else DOSSIER="$HOME/Applications"; fi
APP="$DOSSIER/$NOM_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/ResterActif" "$APP/Contents/MacOS/ResterActif"
cat "$dossier/Info.plist" > "$APP/Contents/Info.plist"
cat "$dossier/AppIcon.icns" > "$APP/Contents/Resources/AppIcon.icns"
cat "$dossier/desinstaller.zsh" > "$APP/Contents/Resources/desinstaller.zsh"
codesign --force --sign - "$APP"
print -r -- "Rester actif est installé : $APP"
print -r -- "Si macOS signale un élément d'arrière-plan « rester-actif », laisse-le autorisé : il rétablit la veille après un redémarrage."
print -r -- "Pour tout retirer : zsh \"$dossier/desinstaller.zsh\""
open "$APP"
