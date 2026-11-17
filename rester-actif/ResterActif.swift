// Rester actif, version 6 : garde le Mac éveillé, même capot fermé, pendant une durée choisie.
// L'interface est ici ; le travail administrateur est fait par /usr/local/libexec/rester-actif.

import AppKit
import LocalAuthentication

enum Config {
    static let versionAssistant = "6"
    static let assistant = "/usr/local/libexec/rester-actif"
    static let fichierFin = "/var/run/local.rester-actif.fin"
    static let fichierMotif = "/var/run/local.rester-actif.motif"
    static let minutesMax = 10_080 // une semaine, comme dans l'assistant
}

@main
enum Lanceur {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let controleur = Controleur()
        application.delegate = controleur
        withExtendedLifetime(controleur) {
            application.run()
        }
    }
}

@MainActor
final class Controleur: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var fenetre: NSWindow!
    private let contenu = NSView()
    private let champMinutes = NSTextField(string: "60")
    private let boutonDemarrer = NSButton(title: "Démarrer", target: nil, action: nil)
    private let alerteVeille = NSTextField(wrappingLabelWithString:
        "La veille est encore désactivée, alors qu'aucun compte à rebours ne tourne.")
    private let boutonReactiver = NSButton(title: "Réactiver la veille", target: nil, action: nil)
    private let compteur = NSTextField(labelWithString: "")
    private let heureFin = NSTextField(labelWithString: "")
    private let champAjout = NSTextField(string: "30")
    private let boutonProlonger = NSButton(title: "Prolonger", target: nil, action: nil)
    private let boutonArreter = NSButton(title: "Arrêter", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let groupeDepart = NSStackView()
    private let groupeEnCours = NSStackView()
    private let formatHeure: DateFormatter = {
        let format = DateFormatter()
        format.dateStyle = .none
        format.timeStyle = .short
        return format
    }()
    private let formatJour: DateFormatter = {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("EEEdMMMjjmm")
        return format
    }()
    private var fin: Date?
    private var etaitEnCours: Bool?
    private var occupe = false {
        didSet {
            for bouton in [boutonDemarrer, boutonProlonger, boutonArreter, boutonReactiver] {
                bouton.isEnabled = !occupe
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        construireMenus()
        construireFenetre()
        rafraichir()
        verifierAssistant()
        fenetre.center()
        fenetre.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let horloge = Timer(timeInterval: 1, target: self, selector: #selector(rafraichir),
                            userInfo: nil, repeats: true)
        RunLoop.main.add(horloge, forMode: .common)
    }

    // Rouvrir l'application (Dock, Centre de contrôle) ramène la fenêtre, même réduite.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        fenetre.makeKeyAndOrderFront(nil)
        return true
    }

    // Fermer la fenêtre quitte l'application, et le compte à rebours continue sans elle.
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // MARK: - Interface

    private func construireMenus() {
        let barre = NSMenu()
        let menuApp = NSMenu()
        menuApp.addItem(withTitle: "Fermer la fenêtre",
                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menuApp.addItem(withTitle: "Quitter Rester actif",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let menuEdition = NSMenu(title: "Édition")
        menuEdition.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menuEdition.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menuEdition.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menuEdition.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for sousMenu in [menuApp, menuEdition] {
            let item = NSMenuItem()
            item.submenu = sousMenu
            barre.addItem(item)
        }
        NSApp.mainMenu = barre
    }

    private func construireFenetre() {
        let invite = NSTextField(labelWithString: "Combien de minutes ?")
        invite.font = NSFont.boldSystemFont(ofSize: 15)
        centrer(champMinutes, largeur: 120)
        relier(boutonDemarrer, a: #selector(demarrer))
        alerteVeille.textColor = NSColor.systemOrange
        alerteVeille.alignment = .center
        alerteVeille.preferredMaxLayoutWidth = 272
        relier(boutonReactiver, a: #selector(arreter))
        empiler(groupeDepart, [invite, champMinutes, boutonDemarrer, alerteVeille, boutonReactiver])

        compteur.font = NSFont.monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        heureFin.textColor = NSColor.secondaryLabelColor
        centrer(champAjout, largeur: 60)
        relier(boutonProlonger, a: #selector(prolonger))
        relier(boutonArreter, a: #selector(arreter))
        let ligneAjout = NSStackView(views: [champAjout, NSTextField(labelWithString: "min"), boutonProlonger])
        ligneAjout.spacing = 8
        empiler(groupeEnCours, [compteur, heureFin, ligneAjout, boutonArreter])

        message.alignment = .center
        message.preferredMaxLayoutWidth = 272
        message.isHidden = true

        let pile = NSStackView()
        empiler(pile, [groupeDepart, groupeEnCours, message])
        pile.spacing = 14
        pile.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        pile.translatesAutoresizingMaskIntoConstraints = false
        contenu.addSubview(pile)
        NSLayoutConstraint.activate([
            pile.leadingAnchor.constraint(equalTo: contenu.leadingAnchor),
            pile.trailingAnchor.constraint(equalTo: contenu.trailingAnchor),
            pile.topAnchor.constraint(equalTo: contenu.topAnchor),
            pile.bottomAnchor.constraint(equalTo: contenu.bottomAnchor),
            contenu.widthAnchor.constraint(equalToConstant: 320)
        ])

        fenetre = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        fenetre.title = "Rester actif"
        fenetre.isReleasedWhenClosed = false
        fenetre.contentView = contenu
        fenetre.delegate = self
    }

    private func centrer(_ champ: NSTextField, largeur: CGFloat) {
        champ.alignment = .center
        champ.widthAnchor.constraint(equalToConstant: largeur).isActive = true
    }

    private func relier(_ bouton: NSButton, a action: Selector) {
        bouton.target = self
        bouton.action = action
    }

    private func empiler(_ pile: NSStackView, _ vues: [NSView]) {
        vues.forEach { pile.addArrangedSubview($0) }
        pile.orientation = .vertical
        pile.alignment = .centerX
        pile.spacing = 12
    }

    // MARK: - État

    private func verifierAssistant() {
        switch Systeme.versionAssistant() {
        case Config.versionAssistant?: break
        case nil: afficher("L'assistant administrateur est absent : lance l'installeur.", erreur: true)
        default: afficher("L'assistant administrateur n'est pas à jour : relance l'installeur.", erreur: true)
        }
    }

    @objc private func rafraichir() {
        fin = Systeme.finDuCompteARebours()
        let enCours = (fin != nil)
        if let fin {
            compteur.stringValue = texteDuree(fin.timeIntervalSinceNow)
            heureFin.stringValue = "Mac éveillé jusqu'à " + texteFin(fin)
        }
        guard enCours != etaitEnCours else {
            // Rare : l'avertissement disparaît dès que la veille est rétablie, même sans changement d'état.
            if !enCours, !alerteVeille.isHidden, !Systeme.veilleDesactivee() {
                montrerAlerteVeille(false)
                ajusterTaille()
            }
            return
        }
        let avant = etaitEnCours
        etaitEnCours = enCours
        groupeDepart.isHidden = enCours
        groupeEnCours.isHidden = !enCours
        boutonDemarrer.keyEquivalent = enCours ? "" : "\r"
        boutonProlonger.keyEquivalent = enCours ? "\r" : ""
        // Fin de session : l'explication éventuelle remplace un ancien message. Après une action,
        // le message renvoyé par l'assistant est gardé.
        if !enCours, avant == true || message.isHidden {
            afficher(Systeme.motifDeFin(), erreur: false)
        }
        // Après le message : pendant l'appel à pmset, la fin d'une action peut afficher son erreur.
        montrerAlerteVeille(!enCours && Systeme.veilleDesactivee())
        ajusterTaille()
        fenetre.makeFirstResponder(enCours ? champAjout : champMinutes)
    }

    private func montrerAlerteVeille(_ visible: Bool) {
        alerteVeille.isHidden = !visible
        boutonReactiver.isHidden = !visible
    }

    private func texteDuree(_ intervalle: TimeInterval) -> String {
        let total = max(0, Int(intervalle.rounded(.up)))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%ld:%02ld:%02ld", h, m, s) : String(format: "%02ld:%02ld", m, s)
    }

    // « 14:30 » aujourd'hui, « demain 14:30 », sinon le jour et la date : une session peut durer une semaine.
    private func texteFin(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return formatHeure.string(from: date) }
        if Calendar.current.isDateInTomorrow(date) { return "demain " + formatHeure.string(from: date) }
        return formatJour.string(from: date)
    }

    // MARK: - Actions

    // Démarrer compte la durée à partir de la validation ; Prolonger l'ajoute à la fin actuelle.
    private enum Demande {
        case duree(Int)
        case ajout(Int)
    }

    @objc private func demarrer() {
        guard let minutes = minutesSaisies(champMinutes) else { return }
        lancerAvecConfirmation(.duree(minutes * 60))
    }

    @objc private func prolonger() {
        guard let fin, let minutes = minutesSaisies(champAjout) else { return }
        guard Int(fin.timeIntervalSinceNow.rounded(.up)) + minutes * 60 <= Config.minutesMax * 60 else {
            afficher("La durée totale ne peut pas dépasser une semaine.", erreur: true)
            return
        }
        lancerAvecConfirmation(.ajout(minutes * 60))
    }

    // Arrêter rétablit seulement la veille normale : aucune confirmation n'est demandée.
    @objc private func arreter() {
        guard !occupe else { return }
        occupe = true
        Task { await executer(["stop"]) }
    }

    // Garder le Mac éveillé demande Touch ID, ou le mot de passe de la session à défaut.
    private func lancerAvecConfirmation(_ demande: Demande) {
        guard !occupe else { return }
        occupe = true
        Task {
            do {
                _ = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                         localizedReason: "garder le Mac éveillé")
            } catch {
                occupe = false
                let codesAnnulation: [LAError.Code] = [.userCancel, .systemCancel]
                let annule = (error as? LAError).map { codesAnnulation.contains($0.code) } ?? false
                afficher(annule ? "Action annulée." : error.localizedDescription, erreur: !annule)
                return
            }
            // Calcul fait après la validation : le temps passé sur Touch ID ne change pas l'heure de fin.
            let secondes: Int
            switch demande {
            case .duree(let duree):
                secondes = duree
            case .ajout(let ajout):
                let restant = Systeme.finDuCompteARebours().map { max(0, Int($0.timeIntervalSinceNow.rounded(.up))) } ?? 0
                secondes = restant + ajout // ne dépasse pas une semaine : le reste ne fait que diminuer depuis la vérification
            }
            await executer(["start", String(secondes)])
        }
    }

    // L'assistant tourne hors du fil principal : la fenêtre et le compteur restent fluides.
    private func executer(_ arguments: [String]) async {
        let erreur = await Task.detached { Systeme.executerAssistant(arguments) }.value
        occupe = false
        afficher(erreur, erreur: true)
        etaitEnCours = nil // force la mise à jour complète de la fenêtre
        rafraichir()
    }

    private func minutesSaisies(_ champ: NSTextField) -> Int? {
        let texte = champ.stringValue.trimmingCharacters(in: .whitespaces)
        if let minutes = Int(texte), (1...Config.minutesMax).contains(minutes) {
            return minutes
        }
        afficher("Entre un nombre entier de minutes, entre 1 et \(Config.minutesMax) (une semaine).", erreur: true)
        return nil
    }

    private func afficher(_ texte: String?, erreur: Bool) {
        message.stringValue = texte ?? ""
        message.textColor = erreur ? NSColor.systemRed : NSColor.secondaryLabelColor
        message.isHidden = (texte == nil)
        ajusterTaille()
    }

    private func ajusterTaille() {
        contenu.layoutSubtreeIfNeeded()
        fenetre.setContentSize(contenu.fittingSize)
    }
}

// Accès au système, utilisable depuis n'importe quel fil.
enum Systeme {
    // Heure de fin écrite par l'assistant. Le fichier disparaît juste après la réactivation de la veille ;
    // la marge de 10 secondes évite d'annoncer la fin avant que la veille soit réellement rétablie.
    static func finDuCompteARebours() -> Date? {
        guard let texte = lire(Config.fichierFin), let secondes = TimeInterval(texte) else { return nil }
        let fin = Date(timeIntervalSince1970: secondes)
        return fin.timeIntervalSinceNow > -10 ? fin : nil
    }

    // Pourquoi la dernière session s'est arrêtée d'elle-même, s'il y a lieu.
    static func motifDeFin() -> String? {
        switch lire(Config.fichierMotif) {
        case "batterie"?: return "La dernière session s'est arrêtée : la batterie était à 10 % ou moins."
        case "redemarrage"?: return "La dernière session a été interrompue par un redémarrage ; la veille a été rétablie."
        default: return nil
        }
    }

    // Lit « SleepDisabled » dans pmset, ce qui ne demande aucun droit particulier.
    static func veilleDesactivee() -> Bool {
        guard let sortie = lancer("/usr/bin/pmset", ["-g"])?.sortie else { return false }
        return sortie.split(separator: "\n").contains { ligne in
            ligne.split(whereSeparator: \.isWhitespace) == ["SleepDisabled", "1"]
        }
    }

    static func versionAssistant() -> String? {
        guard let resultat = lancer(Config.assistant, ["version"]), resultat.code == 0 else { return nil }
        return resultat.sortie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Lance l'assistant en administrateur grâce à l'autorisation posée par l'installeur.
    // Renvoie nil si tout va bien, sinon un message d'erreur.
    static func executerAssistant(_ arguments: [String]) -> String? {
        guard let resultat = lancer("/usr/bin/sudo", ["-n", Config.assistant] + arguments) else {
            return "Impossible de lancer sudo."
        }
        guard resultat.code != 0 else { return nil }
        if resultat.erreurs.contains("password is required")
            || !FileManager.default.isExecutableFile(atPath: Config.assistant) {
            return "L'autorisation administrateur est absente : relance l'installeur."
        }
        let message = resultat.erreurs.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Erreur \(resultat.code)." : message
    }

    private static func lire(_ chemin: String) -> String? {
        let texte = try? String(contentsOfFile: chemin, encoding: .utf8)
        return texte?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lancer(_ programme: String, _ arguments: [String])
        -> (code: Int32, sortie: String, erreurs: String)? {
        let tache = Process()
        tache.executableURL = URL(fileURLWithPath: programme)
        tache.arguments = arguments
        let sortie = Pipe()
        let erreurs = Pipe()
        tache.standardOutput = sortie
        tache.standardError = erreurs
        do {
            try tache.run()
        } catch {
            return nil
        }
        // Les sorties sont courtes : les lire l'une après l'autre ne peut pas bloquer.
        let texteSortie = String(decoding: sortie.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let texteErreurs = String(decoding: erreurs.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        tache.waitUntilExit()
        return (tache.terminationStatus, texteSortie, texteErreurs)
    }
}
