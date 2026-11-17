//
//  Relancer : relance l'application au premier plan avec Contrôle + Option + Commande + R,
//  dans toutes les applications.
//
//  Ce programme tourne en arrière-plan, sans fenêtre ni icône. Il enregistre la combinaison
//  de touches directement auprès de macOS, comme le font les lanceurs d'applications. Elle ne
//  passe donc pas par le menu Services de l'app au premier plan, que les apps Catalyst
//  (WhatsApp, Messages) et Electron (VS Code, Slack, Discord) ne traitent pas de façon fiable.
//
//  À chaque appui, il demande à l'app au premier plan de quitter, exactement comme
//  Commande + Q, attend qu'elle soit vraiment fermée, puis la rouvre. Le Finder est traité
//  comme dans « Forcer à quitter > Relancer » : il est arrêté et macOS le relance lui-même.
//
//  Certaines apps (Mail, WhatsApp) ferment leurs fenêtres tout de suite, mais gardent leur
//  processus en vie de longues secondes. Pour ne pas attendre, le programme arrête ce
//  processus un peu moins d'une seconde après la disparition des fenêtres, puis rouvre
//  l'app. Une app qui montre encore une fenêtre, par exemple un dialogue d'enregistrement,
//  n'est jamais arrêtée de cette façon.
//
//  Il n'a besoin d'aucune autorisation de confidentialité : ni Accessibilité, ni
//  Surveillance de la saisie, ni Automatisation.
//
//  Journal : ~/Library/Logs/Relancer/Relancer.log
//

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

// ---------------------------------------------------------------------------------------
// Réglages. Pour changer la combinaison de touches, modifie les deux premières lignes,
// puis relance l'installateur.
// ---------------------------------------------------------------------------------------

static const UInt32 kTouche = kVK_ANSI_R;                               // la touche R
static const UInt32 kModificateurs = cmdKey | optionKey | controlKey;   // Commande + Option + Contrôle
static NSString * const kToucheLisible = @"Contrôle + Option + Commande + R";
static NSString * const kVersionDeRelancer = @"2.4";
static const OSType kSignatureDuRaccourci = 0x524C4E43;                            // « RLNC »

static const NSTimeInterval kDoubleAppui = 1.5;       // un second appui plus rapproché est ignoré
static const NSTimeInterval kAttenteReponse = 120.0;  // temps laissé à l'app pour répondre (dialogue d'enregistrement)
static const NSTimeInterval kAttenteFermeture = 60.0; // temps laissé à l'app pour se fermer après avoir accepté
static const NSTimeInterval kAttenteRefus = 30.0;     // surveillance après une réponse « annulé » tardive
static const NSTimeInterval kReponseImmediate = 1.0;  // en dessous, la réponse « annulé » est celle d'une app qui se ferme à sa façon
static const NSTimeInterval kAvantDeForcer = 3.0;     // délai avant de proposer de forcer une app muette

// Les apps qui traînent après avoir fermé leurs fenêtres (voir « SurveillerLaFin »).
// Pour toujours attendre qu'une app se ferme d'elle-même, remplace YES par NO.
static const BOOL kArreterLesAppsQuiTrainent = YES;
static const NSTimeInterval kGrace = 0.8;             // délai laissé à une app qui n'a plus de fenêtre mais tourne encore
static const NSTimeInterval kGraceSansIndice = 3.0;   // le même délai, pour une app qui n'avait déjà aucune fenêtre au départ
static const NSTimeInterval kCalme = 0.4;             // l'app ne doit plus avoir beaucoup écrit sur le disque depuis ce délai
static const uint64_t kEcritureNotable = 256 * 1024;  // « beaucoup » : plus de 256 Ko entre deux relevés
static const NSTimeInterval kGraceMaximum = 5.0;      // au-delà, elle est arrêtée même si elle écrit encore
static const NSTimeInterval kDelaiDeReaction = 1.5;   // avant ce délai, c'est l'app qui se masque ou qui change de bureau, pas toi
static const NSTimeInterval kAvantArretForce = 1.5;   // délai entre le signal d'arrêt et l'arrêt forcé
static const NSTimeInterval kAttenteNouvelleCopie = 0.6;   // temps laissé à la nouvelle copie pour apparaître, avant un nouvel essai

// ---------------------------------------------------------------------------------------
// Une relance en cours : une app à qui on a demandé de quitter, et qu'on rouvrira.
// ---------------------------------------------------------------------------------------

@interface Relance : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic, copy) NSString *nom;
@property (nonatomic, copy) NSString *identifiant;   // identifiant de paquet, parfois absent
@property (nonatomic, copy) NSString *chemin;        // chemin du paquet .app, tel que macOS le donne
@property (nonatomic, strong) NSURL *aRouvrir;       // paquet à rouvrir
@property (nonatomic) BOOL finder;
@property (nonatomic) BOOL reguliere;                // app ordinaire, avec une icône dans le Dock
@property (nonatomic) BOOL enAttente;                // demande envoyée, réponse pas encore reçue
@property (nonatomic) BOOL forcee;
@property (nonatomic) BOOL sourde;                   // l'app ne sait pas traiter la demande de fermeture
@property (nonatomic) BOOL proposee;                 // la question « forcer à quitter ? » a déjà été posée
@property (nonatomic) NSInteger demande;             // numéro de la dernière demande envoyée
@property (nonatomic) NSTimeInterval debut;
@property (nonatomic) NSTimeInterval debutDemande;
@property (nonatomic) NSTimeInterval dernierAppui;
@property (nonatomic) NSTimeInterval limite;         // instant où l'on cesse de surveiller l'app
@property (nonatomic, strong) NSTimer *minuteur;
@property (nonatomic, strong) NSTask *commande;      // commande d'ouverture en cours
@property (nonatomic, strong) NSSet<NSNumber *> *autresCopies;   // autres copies de la même app, déjà ouvertes
@property (nonatomic) BOOL copieAuMemeEndroit;       // une autre copie du même paquet tourne encore
@property (nonatomic) BOOL forcerNouvelleCopie;      // macOS croit encore l'ancienne copie ouverte
@property (nonatomic, strong) NSRunningApplication *app;         // l'app, telle que macOS la décrit
@property (nonatomic, strong) dispatch_source_t sourceDeFin;     // prévient à l'instant où le processus se termine
@property (nonatomic) NSTimeInterval fermeeA;        // instant où le processus s'est terminé
@property (nonatomic) NSInteger fenetresAuDepart;    // fenêtres visibles au moment de l'appui (-1 : inconnu)
@property (nonatomic, strong) NSSet<NSNumber *> *fenetresDeDepart;   // numéros de ces fenêtres visibles
@property (nonatomic, strong) NSSet<NSNumber *> *fenetresConnues;    // numéros de toutes ses fenêtres à ce moment-là, visibles ou non
@property (nonatomic) NSTimeInterval dernierReleve;  // instant du dernier relevé de ses fenêtres
@property (nonatomic) NSInteger dernierALEcran;      // nombre de fenêtres à l'écran lors de ce relevé (-1 : inconnu)
@property (nonatomic) NSTimeInterval discreteDepuis; // instant depuis lequel l'app est tenue pour fermée à l'écran (0 : elle ne l'est pas)
@property (nonatomic) BOOL retraitNote;              // son retrait du Dock est déjà noté dans le journal
@property (nonatomic) NSTimeInterval masqueeDepuis;  // instant où l'app a été vue masquée pour la première fois (0 : jamais)
@property (nonatomic, copy) NSString *attenteNotee;  // dernière raison d'attendre notée dans le journal
@property (nonatomic) uint64_t totalEcrit;           // octets écrits sur le disque par l'app, au dernier relevé
@property (nonatomic) NSTimeInterval derniereEcriture;   // instant de sa dernière écriture observée
@property (nonatomic) NSTimeInterval arretEnvoye;    // instant où le signal d'arrêt lui a été envoyé (0 : jamais)
@property (nonatomic) BOOL arretForce;
@end

@implementation Relance
@end

static NSMutableDictionary<NSNumber *, Relance *> *gRelances;    // relances en cours, par numéro de processus
static NSMutableDictionary<NSString *, NSNumber *> *gRouvertes;  // chemin du paquet -> instant de la dernière réouverture
static NSString *gJournal;
static NSTimeInterval gGarde = 0;  // jusqu'à cet instant, une app relancée est en train de revenir : aucun autre appui n'est pris
static BOOL gAlerte = NO;      // la fenêtre « forcer à quitter » est affichée
static pid_t gAlertePid = 0;
static BOOL gEssai = NO;       // mode d'essai, utilisé par l'installateur
static id gActivite;
static NSTimeInterval gChangementDEspace = 0;   // instant du dernier changement de bureau
static id gObservateurDEspace;

static void AppuiRecu(void);
static void AppuiSuivant(Relance *r);
static void LancerRelance(NSRunningApplication *app);
static void EnvoyerDemande(Relance *r);
static void ReponseRecue(pid_t pid, NSInteger numero, OSStatus code);
static void Tic(Relance *r);
static void SurveillerLaFin(Relance *r, NSTimeInterval t);
static Relance *RelanceQuiQuitteLEcran(void);
static void FinDuProcessus(Relance *r);
static void Retirer(Relance *r);
static void AppFermee(Relance *r, NSTimeInterval t);
static void AttendreLaRadiation(Relance *r, NSTimeInterval fin);
static void AttendreLeFinder(Relance *r, NSInteger essai);
static void RamenerLeFinder(pid_t nouveau, NSInteger essai);
static void Rouvrir(Relance *r, NSInteger essai);
static void ChercherLaNouvelleCopie(Relance *r, NSInteger essai, NSTimeInterval fin);
static void Reessayer(Relance *r, NSInteger essai, NSString *detail);
static void AttendreLePremierPlan(Relance *r, pid_t nouveau, NSTimeInterval fin);
static void ProposerDeForcer(Relance *r);

// ---------------------------------------------------------------------------------------
// Outils
// ---------------------------------------------------------------------------------------

// Temps écoulé depuis le démarrage du Mac : il ne recule jamais, même si l'heure change.
static NSTimeInterval Maintenant(void) {
    return [NSProcessInfo processInfo].systemUptime;
}

static void Journal(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Journal(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    static NSDateFormatter *horodatage = nil;
    if (horodatage == nil) {
        horodatage = [[NSDateFormatter alloc] init];
        horodatage.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        horodatage.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    }
    NSString *ligne = [NSString stringWithFormat:@"%@  %@\n", [horodatage stringFromDate:[NSDate date]], message];
    if (gJournal != nil) {
        FILE *fichier = fopen(gJournal.fileSystemRepresentation, "a");
        if (fichier != NULL) {
            fputs(ligne.UTF8String, fichier);
            fclose(fichier);
        }
    }
    if (gEssai) {
        fputs(ligne.UTF8String, stdout);
        fflush(stdout);
    }
}

// En mode d'essai, le programme s'arrête dès que le résultat est connu.
static void FinEssai(int code) {
    if (gEssai) {
        fflush(stdout);
        exit(code);
    }
}

static BOOL EstVivant(pid_t pid) {
    if (kill(pid, 0) == 0) return YES;
    return errno == EPERM;   // le processus existe, mais appartient à quelqu'un d'autre
}

static void Refus(NSString *nom, NSString *raison) {
    Journal(@"appui : « %@ » n'est pas relancée, %@", nom, raison);
    NSBeep();
    FinEssai(1);
}

// Les fenêtres ordinaires d'une app, telles que macOS les décrit : celles qui sont à l'écran
// en ce moment (partout = NO), ou toutes celles qui existent, y compris sur un autre bureau,
// réduites dans le Dock ou masquées (partout = YES). « fiable » reçoit NO quand macOS ne nous
// montre aucune fenêtre d'une autre app : la réponse ne veut alors rien dire.
// Cette liste ne demande aucune autorisation : elle ne contient ni le titre ni le contenu des
// fenêtres, seulement leur propriétaire, leur numéro, leur taille et leur niveau.
static NSArray<NSDictionary *> *FenetresDe(pid_t pid, BOOL partout, BOOL *fiable) {
    *fiable = NO;
    CGWindowListOption quoi = partout ? kCGWindowListOptionAll : kCGWindowListOptionOnScreenOnly;
    CFArrayRef liste = CGWindowListCopyWindowInfo(quoi | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (liste == NULL) return @[];
    NSArray *toutes = CFBridgingRelease(liste);
    NSMutableArray<NSDictionary *> *resultat = [NSMutableArray array];
    pid_t moi = getpid();
    for (NSDictionary *fenetre in toutes) {
        NSNumber *proprietaire = fenetre[(__bridge NSString *)kCGWindowOwnerPID];
        if (proprietaire == nil) continue;
        if (proprietaire.intValue != moi) *fiable = YES;
        if (proprietaire.intValue != pid) continue;
        // Dans le doute, une fenêtre compte : elle n'est écartée que si l'on est sûr qu'elle
        // n'est pas une vraie fenêtre.
        NSNumber *niveau = fenetre[(__bridge NSString *)kCGWindowLayer];
        if (niveau != nil && (niveau.integerValue < 0 || niveau.integerValue >= 20)) continue;   // Dock, barre des menus, menus
        NSNumber *opacite = fenetre[(__bridge NSString *)kCGWindowAlpha];
        if (opacite != nil && opacite.doubleValue < 0.02) continue;                             // fenêtre invisible
        NSDictionary *bornes = fenetre[(__bridge NSString *)kCGWindowBounds];
        CGRect cadre = CGRectZero;
        if (bornes != nil && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bornes, &cadre)
            && (cadre.size.width < 40.0 || cadre.size.height < 40.0)) continue;                 // fenêtre technique minuscule
        [resultat addObject:fenetre];
    }
    return resultat;
}

// Nombre d'octets que l'app a écrits sur le disque depuis son lancement : il sert à savoir si
// elle est encore en train d'enregistrer quelque chose. UINT64_MAX si macOS ne le dit pas.
static uint64_t OctetsEcrits(pid_t pid) {
    struct rusage_info_v2 mesure;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&mesure) != 0) return UINT64_MAX;
    return mesure.ri_diskio_byteswritten;
}

// Une app pour iPhone ou iPad installée sur le Mac tourne dans « Nom.app/Wrapper/Nom.app » :
// c'est le paquet extérieur qu'il faut rouvrir.
static NSURL *PaquetARouvrir(NSURL *paquet) {
    NSString *parent = paquet.path.stringByDeletingLastPathComponent;
    if ([parent.lastPathComponent isEqualToString:@"Wrapper"]) {
        NSString *exterieur = parent.stringByDeletingLastPathComponent;
        if ([exterieur.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame) {
            return [NSURL fileURLWithPath:exterieur isDirectory:YES];
        }
    }
    return paquet;
}

// ---------------------------------------------------------------------------------------
// La demande de fermeture
// ---------------------------------------------------------------------------------------

// Envoie à l'app l'événement « quitter », le même que Commande + Q ou que le menu du Dock,
// et attend sa réponse. Renvoie 0 si elle accepte, sinon le numéro d'erreur.
// Appelée hors du fil principal, car la réponse peut tarder (dialogue d'enregistrement).
static OSStatus DemanderDeQuitter(pid_t pid) {
    @autoreleasepool {
        NSAppleEventDescriptor *cible = [NSAppleEventDescriptor descriptorWithProcessIdentifier:pid];
        NSAppleEventDescriptor *evenement =
            [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass
                                                     eventID:kAEQuitApplication
                                            targetDescriptor:cible
                                                    returnID:kAutoGenerateReturnID
                                               transactionID:kAnyTransactionID];
        NSError *erreur = nil;
        NSAppleEventDescriptor *reponse =
            [evenement sendEventWithOptions:(NSAppleEventSendWaitForReply | NSAppleEventSendCanInteract | NSAppleEventSendCanSwitchLayer)
                                    timeout:kAttenteReponse
                                      error:&erreur];
        if (reponse == nil) {
            return erreur != nil ? (OSStatus)erreur.code : (OSStatus)-1;
        }
        // Quand l'app refuse, son numéro d'erreur se trouve dans la réponse.
        NSAppleEventDescriptor *numero = [reponse paramDescriptorForKeyword:keyErrorNumber];
        return numero != nil ? (OSStatus)numero.int32Value : (OSStatus)0;
    }
}

static void EnvoyerDemande(Relance *r) {
    NSTimeInterval t = Maintenant();
    r.demande = r.demande + 1;
    r.enAttente = YES;
    r.sourde = NO;
    r.proposee = NO;
    r.debutDemande = t;
    r.limite = t + kAttenteReponse + 5.0;
    pid_t pid = r.pid;
    NSInteger numero = r.demande;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        OSStatus code = DemanderDeQuitter(pid);
        dispatch_async(dispatch_get_main_queue(), ^{
            ReponseRecue(pid, numero, code);
        });
    });
}

static void ReponseRecue(pid_t pid, NSInteger numero, OSStatus code) {
    Relance *r = gRelances[@(pid)];
    if (r == nil || r.demande != numero) return;   // l'app est déjà fermée, ou une demande plus récente est partie
    r.enAttente = NO;
    NSTimeInterval t = Maintenant();
    NSTimeInterval duree = t - r.debutDemande;

    if (code == 0) {
        Journal(@"« %@ » accepte de quitter (réponse en %.1f s)", r.nom, duree);
        r.limite = t + kAttenteFermeture;
    } else if (code == -128) {
        // « Annulé ». Une réponse immédiate est celle des apps Electron (VS Code, Slack,
        // Discord) : elles répondent ainsi, puis se ferment d'elles-mêmes, parfois après t'avoir
        // demandé d'enregistrer. Elles ont donc le même délai qu'une app classique qui affiche
        // un dialogue d'enregistrement. Une réponse tardive est celle d'une app où tu as cliqué
        // sur Annuler : la surveillance est alors plus courte.
        NSTimeInterval attente = duree < kReponseImmediate ? kAttenteReponse : kAttenteRefus;
        Journal(@"« %@ » répond « annulé » après %.1f s : je la surveille encore %.0f s, car certaines apps répondent ainsi puis se ferment",
                r.nom, duree, attente);
        r.limite = t + attente;
    } else if (code == -1712) {
        Journal(@"« %@ » n'a pas répondu en %.0f s : j'arrête là", r.nom, duree);
        r.limite = t;
    } else if (code == -609 || code == -600) {
        // La liaison s'est coupée : l'app est en train de se fermer, ou vient d'être forcée à quitter.
        Journal(@"« %@ » se ferme (code %d)", r.nom, (int)code);
        r.limite = t + 10.0;
    } else if (code == -1708 || code == -1717) {
        // L'app ne sait pas traiter la demande de fermeture. On la lui refait par une autre
        // voie ; si elle est toujours ouverte 3 secondes plus tard, on te demande s'il faut la
        // forcer à quitter. Elle n'est jamais arrêtée de force sans ton accord.
        Journal(@"« %@ » ne comprend pas la demande de fermeture (code %d) : nouvel essai par une autre voie", r.nom, (int)code);
        NSRunningApplication *cible = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        [cible terminate];
        r.sourde = YES;
        r.limite = t + 3.0;
    } else if (code == -1743 || code == -10004) {
        Journal(@"macOS refuse la demande de fermeture (code %d) : nouvel essai par une autre voie", (int)code);
        NSRunningApplication *cible = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        [cible terminate];
        r.limite = t + kAttenteFermeture;
    } else {
        Journal(@"« %@ » renvoie l'erreur %d : je la surveille encore 10 s", r.nom, (int)code);
        r.limite = t + 10.0;
    }
}

// ---------------------------------------------------------------------------------------
// La surveillance, vingt fois par seconde tant qu'une relance est en cours
// ---------------------------------------------------------------------------------------

static void Retirer(Relance *r) {
    [r.minuteur invalidate];
    r.minuteur = nil;
    if (r.sourceDeFin != nil) {
        dispatch_source_cancel(r.sourceDeFin);
        r.sourceDeFin = nil;
    }
    if (gRelances[@(r.pid)] == r) [gRelances removeObjectForKey:@(r.pid)];
    if (gAlerte && gAlertePid == r.pid) {
        // La fenêtre « forcer à quitter » concerne cette app : elle n'a plus lieu d'être. C'est un
        // minuteur qui la referme, juste après, pour que la suite de la relance (la réouverture)
        // ne dépende en rien de cette fermeture.
        pid_t pid = r.pid;
        NSTimer *fermeture = [NSTimer timerWithTimeInterval:0.0 repeats:NO block:^(NSTimer *m) {
            if (gAlerte && gAlertePid == pid) [NSApp abortModal];
        }];
        [[NSRunLoop mainRunLoop] addTimer:fermeture forMode:NSRunLoopCommonModes];
    }
}

static void Tic(Relance *r) {
    if (gRelances[@(r.pid)] != r) {
        [r.minuteur invalidate];
        r.minuteur = nil;
        return;
    }
    NSTimeInterval t = Maintenant();
    if (!EstVivant(r.pid)) {
        FinDuProcessus(r);
        return;
    }
    if (kArreterLesAppsQuiTrainent && !r.finder) SurveillerLaFin(r, t);
    if (t < r.limite) return;
    if (r.finder && !r.forcee) {
        r.forcee = YES;
        r.limite = t + 5.0;
        Journal(@"le Finder ne s'est pas arrêté : arrêt forcé");
        kill(r.pid, SIGKILL);
        return;
    }
    if (r.sourde && !r.proposee && !gEssai) {
        // La question est posée par un autre minuteur, pour que cette surveillance continue
        // pendant que la fenêtre est affichée.
        r.proposee = YES;
        r.limite = t + 75.0;
        NSTimer *question = [NSTimer timerWithTimeInterval:0.0 repeats:NO block:^(NSTimer *m) {
            if (gRelances[@(r.pid)] == r && !gAlerte) ProposerDeForcer(r);
        }];
        [[NSRunLoop mainRunLoop] addTimer:question forMode:NSRunLoopCommonModes];
        return;
    }
    Retirer(r);
    Journal(@"« %@ » est restée ouverte : je n'insiste pas", r.nom);
    FinEssai(1);
}

// Le processus de l'app vient de se terminer : on passe à la réouverture.
static void FinDuProcessus(Relance *r) {
    if (gRelances[@(r.pid)] != r) return;
    Retirer(r);
    AppFermee(r, Maintenant());
}

// ---------------------------------------------------------------------------------------
// Les apps qui traînent
// ---------------------------------------------------------------------------------------
//
// Après une demande de fermeture, certaines apps ferment leurs fenêtres tout de suite mais
// gardent leur processus en vie de longues secondes : WhatsApp se retire du Dock et continue
// en arrière-plan, Mail termine ses échanges avec ses serveurs. macOS 27 appelle cela
// « Exécution en arrière-plan » et propose de l'arrêter depuis le Dock. On fait ici la même
// chose, automatiquement : quand l'app n'a plus aucune fenêtre à l'écran depuis kGrace et
// qu'elle n'écrit plus sur le disque, son processus est arrêté, puis l'app est rouverte.
//
// Une app qui attend peut-être ta réponse n'est jamais arrêtée de cette façon :
//   - si elle montre une fenêtre à l'écran, par exemple un dialogue d'enregistrement ;
//   - si elle a ouvert une fenêtre depuis l'appui, même sur un autre bureau ou masquée ;
//   - si les fenêtres qu'elle montrait existent encore et que tu as masqué l'app ou changé de
//     bureau depuis l'appui : elles ont alors quitté l'écran pour une tout autre raison.

// >>> décision (cette partie est aussi vérifiée à part, cas par cas, avant chaque livraison)

// Ce que l'on observe d'une app à qui l'on a demandé de quitter, à un instant donné.
typedef struct {
    BOOL listeFiable;      // macOS nous montre bien les fenêtres des autres apps
    NSInteger aLEcran;     // nombre de fenêtres qu'elle montre à l'écran
    BOOL nouvelle;         // elle a ouvert, depuis l'appui, une fenêtre qui n'est pas à l'écran
    NSInteger restantes;   // fenêtres visibles à l'appui qui existent encore, hors de l'écran
    NSInteger ailleurs;    // toutes ses fenêtres qui existent hors de l'écran (autre bureau, masquées, réduites)
    NSInteger auDepart;    // nombre de fenêtres qu'elle montrait à l'appui (-1 : inconnu)
    BOOL retiree;          // elle s'est retirée du Dock
    BOOL deplacee;         // tu l'as masquée, ou tu as changé de bureau, après l'appui
} Constat;

typedef enum {
    kAttendre = 0,         // elle attend peut-être ta réponse, ou rien ne permet de conclure
    kFermeeIndiceFort,     // elle a quitté l'écran d'elle-même : seul son processus tourne encore
    kFermeeIndiceFaible    // elle n'a aucune fenêtre, mais n'en avait déjà aucune à l'appui
} Jugement;

// Décide si l'app peut être tenue pour « fermée à l'écran ». Dans le doute, la réponse est
// kAttendre. « raison » reçoit, quand il y en a une, l'explication à noter dans le journal.
static Jugement Juger(Constat o, const char **raison) {
    *raison = NULL;
    if (!o.listeFiable) {
        // Sans la liste des fenêtres, seul le retrait du Dock fait foi.
        if (o.retiree) return kFermeeIndiceFort;
        *raison = "la liste des fenêtres n'est pas disponible";
        return kAttendre;
    }
    if (o.aLEcran > 0) {
        // Elle montre une fenêtre : peut-être un dialogue.
        if (o.retiree) *raison = "elle s'est retirée du Dock, mais elle montre encore une fenêtre à l'écran";
        return kAttendre;
    }
    if (o.retiree) return kFermeeIndiceFort;               // elle a quitté le Dock : elle en a fini avec toi
    if (o.nouvelle) {
        *raison = "elle a ouvert une fenêtre depuis l'appui, hors de l'écran";
        return kAttendre;
    }
    if (o.auDepart > 0 && o.restantes == 0) return kFermeeIndiceFort;   // elle a détruit toutes ses fenêtres visibles
    if (o.deplacee) {
        *raison = "tu l'as masquée, ou tu as changé de bureau, depuis l'appui";
        return kAttendre;
    }
    // Ses fenêtres ont quitté l'écran sans que tu aies rien fait : elle les a fermées.
    if (o.auDepart > 0) return kFermeeIndiceFort;
    // Elle ne montrait aucune fenêtre à l'appui. Si elle en a ailleurs qu'à l'écran, l'une
    // d'elles attend peut-être ta réponse.
    if (o.ailleurs > 0) {
        *raison = "elle ne montrait aucune fenêtre à l'appui, mais elle en a ailleurs qu'à l'écran";
        return kAttendre;
    }
    return kFermeeIndiceFaible;
}

// <<< décision

// Note dans le journal pourquoi une app qui ne montre plus de fenêtre n'est pas arrêtée, une
// seule fois par raison.
static void NoterLAttente(Relance *r, NSString *raison) {
    if ([r.attenteNotee isEqualToString:raison]) return;
    r.attenteNotee = raison;
    Journal(@"« %@ » tourne encore, mais je ne l'arrête pas : %@", r.nom, raison);
}

// Relève ce que l'on observe de l'app en ce moment.
static Constat Constater(Relance *r, NSTimeInterval t) {
    Constat o;
    o.listeFiable = NO;
    o.aLEcran = 0;
    o.nouvelle = NO;
    o.restantes = 0;
    o.ailleurs = 0;
    o.auDepart = r.fenetresAuDepart;

    // L'app s'est-elle retirée du Dock ? C'est ce que fait WhatsApp en quittant. On pose la
    // question à macOS à chaque fois, sans se fier à une réponse plus ancienne. Une app que
    // macOS a déjà rayée de sa liste des apps ouvertes, mais dont le processus tourne encore,
    // est dans le même cas.
    NSRunningApplication *actuelle = [NSRunningApplication runningApplicationWithProcessIdentifier:r.pid];
    BOOL reguliere = (r.app.activationPolicy == NSApplicationActivationPolicyRegular);
    if (actuelle != nil && actuelle.activationPolicy != NSApplicationActivationPolicyRegular) reguliere = NO;
    o.retiree = (r.reguliere && !reguliere) || r.app.terminated;

    // Est-elle masquée, ou as-tu changé de bureau ? Dans la seconde et demie qui suit l'appui,
    // c'est l'app elle-même qui en est la cause, en se fermant : cela ne compte pas.
    BOOL masquee = r.app.hidden || (actuelle != nil && actuelle.hidden);
    if (masquee && r.masqueeDepuis == 0) r.masqueeDepuis = t;
    if (!masquee) r.masqueeDepuis = 0;
    BOOL masqueeParToi = masquee && (r.masqueeDepuis - r.debut >= kDelaiDeReaction);
    BOOL bureauChange = (gChangementDEspace - r.debut >= kDelaiDeReaction);
    o.deplacee = masqueeParToi || bureauChange;

    // Ses fenêtres : combien à l'écran et, s'il n'y en a plus, lesquelles existent encore.
    BOOL fiable = NO;
    NSArray<NSDictionary *> *visibles = FenetresDe(r.pid, NO, &fiable);
    if (!fiable) return o;
    o.listeFiable = YES;
    o.aLEcran = (NSInteger)visibles.count;
    if (o.aLEcran > 0) return o;
    NSArray<NSDictionary *> *toutes = FenetresDe(r.pid, YES, &fiable);
    if (!fiable) {
        o.listeFiable = NO;
        return o;
    }
    o.ailleurs = (NSInteger)toutes.count;
    for (NSDictionary *fenetre in toutes) {
        NSNumber *numero = fenetre[(__bridge NSString *)kCGWindowNumber];
        if (numero == nil || ![r.fenetresConnues containsObject:numero]) o.nouvelle = YES;
        else if ([r.fenetresDeDepart containsObject:numero]) o.restantes += 1;
    }
    return o;
}

static void SurveillerLaFin(Relance *r, NSTimeInterval t) {
    if (r.arretEnvoye > 0) {
        // Le signal d'arrêt est déjà parti. Une app qui l'intercepte pour se fermer à sa façon
        // a encore kAvantArretForce pour le faire.
        if (!r.arretForce && t - r.arretEnvoye >= kAvantArretForce) {
            r.arretForce = YES;
            Journal(@"« %@ » tourne encore %.1f s après le signal d'arrêt : arrêt forcé", r.nom, t - r.arretEnvoye);
            if (kill(r.pid, SIGKILL) != 0) Journal(@"l'arrêt forcé de « %@ » est refusé par macOS (erreur %d)", r.nom, errno);
        }
        return;
    }
    // Un relevé tous les dixièmes de seconde, puis quatre par seconde quand l'attente dure.
    if (t - r.dernierReleve < (t - r.debut < 10.0 ? 0.09 : 0.24)) return;
    r.dernierReleve = t;

    Constat o = Constater(r, t);
    r.dernierALEcran = o.listeFiable ? o.aLEcran : -1;
    if (o.retiree && !r.retraitNote) {
        r.retraitNote = YES;
        Journal(@"« %@ » s'est retirée du Dock ou de la liste des apps ouvertes (%.1f s après l'appui)", r.nom, t - r.debut);
    }
    const char *raison = NULL;
    Jugement verdict = Juger(o, &raison);
    if (verdict == kAttendre) {
        if (raison != NULL) NoterLAttente(r, [NSString stringWithUTF8String:raison]);
        else r.attenteNotee = nil;
        if (r.discreteDepuis > 0) {
            r.discreteDepuis = 0;
            Journal(@"« %@ » n'est plus tenue pour fermée : je reprends l'attente", r.nom);
        }
        return;
    }

    uint64_t ecrit = OctetsEcrits(r.pid);
    if (r.discreteDepuis == 0) {
        r.discreteDepuis = t;
        r.totalEcrit = ecrit;
        r.derniereEcriture = 0;
        Journal(@"« %@ » n'a plus de fenêtre à l'écran (%.1f s après l'appui ; fenêtres existant ailleurs : %ld, dont %ld montrées à l'appui)",
                r.nom, t - r.debut, (long)o.ailleurs, (long)o.restantes);
        return;
    }
    // Écrit-elle encore beaucoup sur le disque ? Si oui, elle enregistre quelque chose : on la
    // laisse finir, dans la limite de kGraceMaximum.
    if (ecrit != UINT64_MAX && r.totalEcrit != UINT64_MAX && ecrit >= r.totalEcrit) {
        if (ecrit - r.totalEcrit >= kEcritureNotable) r.derniereEcriture = t;
    }
    r.totalEcrit = ecrit;
    NSTimeInterval duree = t - r.discreteDepuis;
    if (duree < (verdict == kFermeeIndiceFort ? kGrace : kGraceSansIndice)) return;
    BOOL calme = (t - r.derniereEcriture >= kCalme);
    if (!calme && duree < kGraceMaximum) return;
    r.arretEnvoye = t;
    r.limite = MAX(r.limite, t + 10.0);
    Journal(@"« %@ » n'a plus de fenêtre depuis %.1f s mais son processus tourne encore : je l'arrête pour la relancer",
            r.nom, duree);
    if (kill(r.pid, SIGTERM) != 0) Journal(@"l'arrêt de « %@ » est refusé par macOS (erreur %d)", r.nom, errno);
}

// Une app en cours de relance qui montrait des fenêtres et n'en montre plus : elle est en
// train de quitter l'écran. Pendant ce court moment, c'est une autre app qui se trouve au
// premier plan, et un appui de plus relancerait la mauvaise app.
static Relance *RelanceQuiQuitteLEcran(void) {
    NSTimeInterval t = Maintenant();
    for (Relance *r in gRelances.allValues) {
        if (r.finder || t - r.debut > 30.0) continue;
        if (r.discreteDepuis > 0 || r.arretEnvoye > 0) return r;
        if (r.fenetresAuDepart > 0) {
            BOOL fiable = NO;
            NSArray<NSDictionary *> *visibles = FenetresDe(r.pid, NO, &fiable);
            if (fiable && visibles.count == 0) return r;
        }
    }
    return nil;
}

// ---------------------------------------------------------------------------------------
// La réouverture
// ---------------------------------------------------------------------------------------

static void AppFermee(Relance *r, NSTimeInterval t) {
    r.fermeeA = t;
    if (r.dernierALEcran > 0 && t - r.debut > 3.0) {
        // Une fermeture longue, fenêtres encore visibles : l'app attendait une réponse, ou
        // travaillait sans avoir fermé ses fenêtres.
        Journal(@"« %@ » est fermée (%.1f s après l'appui ; elle montrait encore %ld fenêtre(s) un instant avant)",
                r.nom, t - r.debut, (long)r.dernierALEcran);
    } else {
        Journal(@"« %@ » est fermée (%.1f s après l'appui)", r.nom, t - r.debut);
    }
    // Tant que l'app n'est pas revenue, c'est une autre app qui se trouve au premier plan :
    // un appui de plus à ce moment-là relancerait la mauvaise app. Il est donc ignoré.
    gGarde = MAX(gGarde, t + (r.finder ? 13.0 : 8.0));
    if (r.finder) {
        AttendreLeFinder(r, 0);
        return;
    }
    // On note les autres copies de la même app qui tournent encore, pour ne pas les confondre
    // avec la copie qui va s'ouvrir. Si l'une d'elles vient du même paquet, il faudra demander
    // explicitement une nouvelle copie, sinon macOS se contenterait de la mettre au premier plan.
    NSMutableSet<NSNumber *> *autres = [NSMutableSet set];
    BOOL auMemeEndroit = NO;
    for (NSRunningApplication *a in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (a.processIdentifier == r.pid || a.terminated) continue;
        NSString *chemin = a.bundleURL.path;
        BOOL memeChemin = (chemin != nil && [chemin isEqualToString:r.chemin]);
        BOOL memeIdentifiant = (r.identifiant != nil && [a.bundleIdentifier isEqualToString:r.identifiant]);
        if (memeChemin) auMemeEndroit = YES;
        if (memeChemin || memeIdentifiant) [autres addObject:@(a.processIdentifier)];
    }
    r.autresCopies = autres;
    r.copieAuMemeEndroit = auMemeEndroit;
    AttendreLaRadiation(r, t + 0.15);
}

// Avant de rouvrir l'app, on attend que macOS l'ait rayée de sa liste des apps ouvertes, 0,15
// seconde au plus : sans cela, il se contenterait de « réactiver » l'app qui vient de se
// fermer, sans rien lancer.
static void AttendreLaRadiation(Relance *r, NSTimeInterval fin) {
    if (r.app == nil || r.app.terminated || Maintenant() >= fin) {
        Rouvrir(r, 1);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AttendreLaRadiation(r, fin);
    });
}

// « Forcer à quitter > Relancer » arrête le Finder et laisse macOS le relancer. On vérifie
// qu'il revient, et on ne l'ouvre nous-mêmes que s'il n'est pas revenu après 12 secondes
// (macOS attend parfois une dizaine de secondes avant de relancer un service).
static void AttendreLeFinder(Relance *r, NSInteger essai) {
    for (NSRunningApplication *a in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"]) {
        if (a.processIdentifier != r.pid && !a.terminated) {
            Journal(@"le Finder est relancé (nouveau pid %d)", (int)a.processIdentifier);
            gRouvertes[r.chemin] = @(Maintenant());
            FinEssai(0);
            gGarde = Maintenant() + 3.5;
            RamenerLeFinder(a.processIdentifier, 0);
            return;
        }
    }
    if (essai >= 240) {
        Journal(@"le Finder n'est pas revenu de lui-même : je l'ouvre");
        r.autresCopies = [NSSet set];
        r.copieAuMemeEndroit = NO;
        Rouvrir(r, 1);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AttendreLeFinder(r, essai + 1);
    });
}

// Le Finder relancé par macOS reste en arrière-plan. Il était au premier plan au moment de
// l'appui : dès qu'il a fini de démarrer (3 secondes au plus), on demande à macOS de l'y
// remettre, sans lui faire ouvrir de nouvelle fenêtre. Si macOS refuse, le Finder reste
// simplement en arrière-plan, comme après « Forcer à quitter > Relancer ».
static void RamenerLeFinder(pid_t nouveau, NSInteger essai) {
    NSRunningApplication *finder = [NSRunningApplication runningApplicationWithProcessIdentifier:nouveau];
    if (finder == nil || finder.terminated) {
        gGarde = Maintenant();
        return;
    }
    if (finder.finishedLaunching || essai >= 30) {
        [finder activateWithOptions:NSApplicationActivateAllWindows];
        gGarde = Maintenant() + 0.3;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RamenerLeFinder(nouveau, essai + 1);
    });
}

// Rouvre l'app avec la commande « open » de macOS, celle qu'utilise aussi le Terminal : elle
// lance l'app et la met au premier plan.
static void Rouvrir(Relance *r, NSInteger essai) {
    gGarde = MAX(gGarde, Maintenant() + 4.0);   // tant que l'app n'est pas revenue, les autres appuis attendent
    NSURL *paquet = r.aRouvrir;
    if (![[NSFileManager defaultManager] fileExistsAtPath:paquet.path]) {
        // L'app a été déplacée ou remplacée pendant sa fermeture (mise à jour) : on la retrouve par son identifiant.
        NSURL *retrouvee = r.identifiant != nil ? [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:r.identifiant] : nil;
        if (retrouvee == nil) {
            Journal(@"impossible de rouvrir « %@ » : %@ n'existe plus", r.nom, paquet.path);
            gGarde = Maintenant();
            NSBeep();
            FinEssai(1);
            return;
        }
        r.aRouvrir = retrouvee;
        paquet = retrouvee;
    }
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    if (gEssai) [arguments addObject:@"-g"];   // pendant l'essai, l'app reste en arrière-plan
    // Une nouvelle copie est demandée explicitement quand une autre copie du même paquet tourne
    // encore, ou quand macOS croit encore ouverte celle qui vient de se fermer.
    if (r.copieAuMemeEndroit || r.forcerNouvelleCopie) [arguments addObject:@"-n"];
    [arguments addObject:paquet.path];

    NSTask *commande = [[NSTask alloc] init];
    commande.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    commande.arguments = arguments;
    commande.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    commande.standardError = [NSFileHandle fileHandleWithNullDevice];
    commande.terminationHandler = ^(NSTask *finie) {
        int code = finie.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            r.commande = nil;
            if (code == 0) {
                ChercherLaNouvelleCopie(r, essai, Maintenant() + kAttenteNouvelleCopie);
            } else {
                // macOS refuse : le plus souvent, il croit encore l'ancienne copie ouverte.
                r.forcerNouvelleCopie = YES;
                Reessayer(r, essai, [NSString stringWithFormat:@"la commande d'ouverture a renvoyé le code %d", code]);
            }
        });
    };
    r.commande = commande;   // la commande reste référencée jusqu'à sa fin
    NSError *erreur = nil;
    if (![commande launchAndReturnError:&erreur]) {
        r.commande = nil;
        Reessayer(r, essai, erreur != nil ? erreur.localizedDescription : @"la commande d'ouverture n'a pas démarré");
    }
}

// La commande d'ouverture a réussi : on vérifie qu'une nouvelle copie de l'app tourne vraiment,
// car juste après une fermeture macOS croit parfois l'app encore ouverte et répond « réussi »
// sans rien lancer. La nouvelle copie est reconnue à son paquet ou à son identifiant.
static void ChercherLaNouvelleCopie(Relance *r, NSInteger essai, NSTimeInterval fin) {
    NSTimeInterval t = Maintenant();
    NSString *autreChemin = r.aRouvrir.path;
    for (NSRunningApplication *a in [[NSWorkspace sharedWorkspace] runningApplications]) {
        pid_t pid = a.processIdentifier;
        if (pid <= 0 || pid == r.pid || a.terminated || [r.autresCopies containsObject:@(pid)]) continue;
        NSString *chemin = a.bundleURL.path;
        BOOL memeChemin = (chemin != nil && ([chemin isEqualToString:r.chemin] || [chemin isEqualToString:autreChemin]));
        BOOL memeIdentifiant = (r.identifiant != nil && [a.bundleIdentifier isEqualToString:r.identifiant]);
        if (memeChemin || memeIdentifiant) {
            Journal(@"« %@ » est rouverte (nouveau pid %d, essai %ld, %.2f s après sa fermeture)",
                    r.nom, (int)pid, (long)essai, t - r.fermeeA);
            gRouvertes[r.chemin] = @(t);
            if (chemin != nil) gRouvertes[chemin] = @(t);
            FinEssai(0);
            if (r.reguliere) {
                gGarde = t + 8.0;
                AttendreLePremierPlan(r, pid, t + 8.0);
            } else {
                gGarde = t + 0.3;   // une app de la barre des menus ne revient pas au premier plan
            }
            return;
        }
    }
    if (t >= fin) {
        // Rien n'est apparu. Si macOS compte encore l'ancienne copie parmi les apps ouvertes,
        // le prochain essai demandera explicitement une nouvelle copie.
        NSRunningApplication *ancienne = [NSRunningApplication runningApplicationWithProcessIdentifier:r.pid];
        if (ancienne != nil && !ancienne.terminated) r.forcerNouvelleCopie = YES;
        Reessayer(r, essai, @"aucune nouvelle copie n'est apparue");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ChercherLaNouvelleCopie(r, essai, fin);
    });
}

static void Reessayer(Relance *r, NSInteger essai, NSString *detail) {
    if (essai >= 8) {
        Journal(@"impossible de rouvrir « %@ » après %ld essais : %@", r.nom, (long)essai, detail);
        gGarde = Maintenant();
        NSBeep();
        FinEssai(1);
        return;
    }
    if (essai == 1) Journal(@"réouverture de « %@ » : %@, nouveaux essais", r.nom, detail);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Rouvrir(r, essai + 1);
    });
}

// Attend que l'app rouverte soit revenue au premier plan (8 secondes au plus), puis accepte
// de nouveau les appuis.
static void AttendreLePremierPlan(Relance *r, pid_t nouveau, NSTimeInterval fin) {
    NSTimeInterval t = Maintenant();
    NSRunningApplication *devant = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (devant != nil && devant.processIdentifier == nouveau) {
        gRouvertes[r.chemin] = @(t);
        gGarde = t;
        return;
    }
    if (t >= fin) {
        gGarde = t;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AttendreLePremierPlan(r, nouveau, fin);
    });
}

// ---------------------------------------------------------------------------------------
// Une app qui ne répond pas, ou qui ne sait pas répondre : on propose de la forcer à quitter,
// jamais sans demander
// ---------------------------------------------------------------------------------------

static void ProposerDeForcer(Relance *r) {
    gAlerte = YES;
    gAlertePid = r.pid;
    BOOL sourde = r.sourde;
    Journal(@"« %@ » %@ : je propose de la forcer à quitter", r.nom,
            sourde ? @"est toujours ouverte" : @"n'a pas encore répondu");

    NSAlert *alerte = [[NSAlert alloc] init];
    alerte.alertStyle = NSAlertStyleWarning;
    if (sourde) {
        alerte.messageText = [NSString stringWithFormat:@"« %@ » ne sait pas répondre à la demande de fermeture.", r.nom];
        alerte.informativeText = @"Tu peux la laisser ouverte, ou la forcer à quitter pour la relancer. Si tu la forces, ses modifications non enregistrées seront perdues.";
        [alerte addButtonWithTitle:@"Laisser ouverte"];
    } else {
        alerte.messageText = [NSString stringWithFormat:@"« %@ » n’a pas encore répondu à la demande de fermeture.", r.nom];
        alerte.informativeText = @"Tu peux attendre sa réponse, ou la forcer à quitter pour la relancer. Si tu la forces, ses modifications non enregistrées seront perdues.";
        [alerte addButtonWithTitle:@"Attendre"];
    }
    [alerte addButtonWithTitle:@"Forcer à quitter et relancer"];
    NSWindow *fenetre = alerte.window;
    fenetre.level = NSStatusWindowLevel;   // visible au-dessus des autres fenêtres

    // Sans réponse au bout d'une minute, la question se referme toute seule.
    NSTimer *delai = [NSTimer timerWithTimeInterval:60.0 repeats:NO block:^(NSTimer *minuteur) {
        [NSApp abortModal];
    }];
    [[NSRunLoop mainRunLoop] addTimer:delai forMode:NSRunLoopCommonModes];

    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse reponse = [alerte runModal];
    [delai invalidate];
    gAlerte = NO;
    gAlertePid = 0;
    [NSApp hide:nil];

    if (reponse != NSAlertSecondButtonReturn) {
        Journal(@"« %@ » n'est pas forcée", r.nom);
        if (sourde && gRelances[@(r.pid)] == r) r.limite = Maintenant();   // on cesse de la surveiller
        return;
    }
    if (gRelances[@(r.pid)] != r || !EstVivant(r.pid)) return;   // elle s'est fermée entre-temps
    Journal(@"« %@ » est forcée à quitter, à ta demande", r.nom);
    r.forcee = YES;
    r.limite = Maintenant() + 10.0;
    kill(r.pid, SIGKILL);
}

// ---------------------------------------------------------------------------------------
// Les appuis
// ---------------------------------------------------------------------------------------

static void LancerRelance(NSRunningApplication *app) {
    NSTimeInterval t = Maintenant();
    pid_t pid = app.processIdentifier;
    NSString *nom = app.localizedName != nil ? app.localizedName : @"(sans nom)";
    NSString *identifiant = app.bundleIdentifier;
    NSURL *paquet = app.bundleURL;
    NSString *chemin = paquet.path;

    // Ce qui n'est jamais relancé.
    if ([identifiant isEqualToString:@"com.apple.loginwindow"]) {
        Refus(nom, @"c'est la fenêtre de session de macOS : l'arrêter fermerait ta session");
        return;
    }
    if (chemin == nil || [chemin.pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame) {
        Refus(nom, @"ce n'est pas une application (.app)");
        return;
    }
    BOOL finder = [identifiant isEqualToString:@"com.apple.finder"];
    if (!finder && app.activationPolicy != NSApplicationActivationPolicyRegular && [chemin hasPrefix:@"/System/"]) {
        Refus(nom, @"c'est un composant de macOS, pas une application");
        return;
    }
    NSNumber *rouverte = gRouvertes[chemin];
    if (rouverte != nil && t - rouverte.doubleValue < kDoubleAppui) {
        Journal(@"appui ignoré : « %@ » vient tout juste d'être relancée", nom);
        return;
    }

    Relance *r = [[Relance alloc] init];
    r.pid = pid;
    r.nom = nom;
    r.identifiant = identifiant;
    r.chemin = chemin;
    r.aRouvrir = PaquetARouvrir(paquet);
    r.finder = finder;
    r.reguliere = (app.activationPolicy == NSApplicationActivationPolicyRegular);
    r.app = app;
    r.fenetresAuDepart = -1;
    if (!finder && kArreterLesAppsQuiTrainent) {
        // Relevé des fenêtres de l'app au moment de l'appui : celles qui sont à l'écran, et
        // toutes celles qui existent. Il sert à reconnaître ensuite une fenêtre nouvelle.
        BOOL fiable = NO, fiableAussi = NO;
        NSArray<NSDictionary *> *toutes = FenetresDe(pid, YES, &fiable);
        NSArray<NSDictionary *> *aLEcran = FenetresDe(pid, NO, &fiableAussi);
        if (fiable && fiableAussi) {
            NSMutableSet<NSNumber *> *connues = [NSMutableSet set];
            NSMutableSet<NSNumber *> *visibles = [NSMutableSet set];
            for (NSDictionary *fenetre in toutes) {
                NSNumber *numero = fenetre[(__bridge NSString *)kCGWindowNumber];
                if (numero != nil) [connues addObject:numero];
            }
            for (NSDictionary *fenetre in aLEcran) {
                NSNumber *numero = fenetre[(__bridge NSString *)kCGWindowNumber];
                if (numero == nil) continue;
                [visibles addObject:numero];
                [connues addObject:numero];
            }
            r.fenetresConnues = connues;
            r.fenetresDeDepart = visibles;
            r.fenetresAuDepart = (NSInteger)aLEcran.count;
        }
    }
    r.debut = t;
    r.dernierAppui = t;
    gRelances[@(pid)] = r;
    // Le nombre de fenêtres n'est pas relevé pour le Finder, ni quand macOS ne le donne pas.
    NSString *fenetres = r.fenetresAuDepart >= 0
        ? [NSString stringWithFormat:@"%ld", (long)r.fenetresAuDepart]
        : @"non comptées";
    Journal(@"appui : relance de « %@ » (pid %d, %@, %@, fenêtres à l'écran : %@)", nom, (int)pid,
            identifiant != nil ? identifiant : @"sans identifiant", chemin, fenetres);

    if (finder) {
        // Comme « Forcer à quitter > Relancer » : le Finder est arrêté, macOS le relance.
        r.limite = t + 3.0;
        kill(pid, SIGTERM);
    } else {
        EnvoyerDemande(r);
    }

    // La fin du processus est signalée à l'instant même où elle se produit, sans attendre le
    // passage suivant de la surveillance. Le travail se fait dans un minuteur, comme pour les
    // appuis, pour ne jamais bloquer la fenêtre « forcer à quitter ».
    dispatch_source_t fin = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT,
                                                   dispatch_get_main_queue());
    if (fin != nil) {
        dispatch_source_set_event_handler(fin, ^{
            NSTimer *aussitot = [NSTimer timerWithTimeInterval:0.0 repeats:NO block:^(NSTimer *m) {
                FinDuProcessus(r);
            }];
            [[NSRunLoop mainRunLoop] addTimer:aussitot forMode:NSRunLoopCommonModes];
        });
        r.sourceDeFin = fin;
        dispatch_resume(fin);
    }

    // La surveillance régulière, vingt fois par seconde : délais d'attente, apps qui traînent,
    // et filet de sécurité si le signalement ci-dessus manquait.
    NSTimer *minuteur = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *m) {
        Tic(r);
    }];
    r.minuteur = minuteur;
    [[NSRunLoop mainRunLoop] addTimer:minuteur forMode:NSRunLoopCommonModes];
}

// Un nouvel appui alors qu'une relance de la même app est déjà en cours.
static void AppuiSuivant(Relance *r) {
    NSTimeInterval t = Maintenant();
    if (t - r.dernierAppui < kDoubleAppui) {
        Journal(@"appui en double ignoré (« %@ »)", r.nom);
        return;
    }
    r.dernierAppui = t;
    if (r.finder) return;
    if (r.enAttente) {
        if (t - r.debutDemande < kAvantDeForcer) {
            Journal(@"appui ignoré : « %@ » n'a pas encore eu le temps de répondre", r.nom);
            return;
        }
        ProposerDeForcer(r);
        return;
    }
    Journal(@"nouvel appui : nouvelle demande de fermeture à « %@ »", r.nom);
    EnvoyerDemande(r);
}

static void AppuiRecu(void) {
    if (gAlerte) return;
    NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (app == nil) {
        Journal(@"appui : aucune application au premier plan");
        NSBeep();
        return;
    }
    if (app.processIdentifier == getpid()) return;
    Relance *r = gRelances[@(app.processIdentifier)];
    if (r != nil) {
        AppuiSuivant(r);
        return;
    }
    if (Maintenant() < gGarde) {
        Journal(@"appui ignoré : une application relancée est en train de revenir au premier plan");
        return;
    }
    Relance *sortante = RelanceQuiQuitteLEcran();
    if (sortante != nil) {
        Journal(@"appui ignoré : « %@ » est en train de se fermer pour être relancée", sortante.nom);
        return;
    }
    LancerRelance(app);
}

// ---------------------------------------------------------------------------------------
// Le raccourci global
// ---------------------------------------------------------------------------------------

static OSStatus GestionnaireDeRaccourci(EventHandlerCallRef suite, EventRef evenement, void *contexte) {
    EventHotKeyID identifiant;
    OSStatus etat = GetEventParameter(evenement, kEventParamDirectObject, typeEventHotKeyID, NULL,
                                      sizeof(identifiant), NULL, &identifiant);
    if (etat == noErr && identifiant.signature == kSignatureDuRaccourci && identifiant.id == 1) {
        // Le travail se fait juste après, hors du traitement de l'événement clavier. Un minuteur
        // est utilisé plutôt que la file d'attente principale : la fenêtre « forcer à quitter »
        // peut ainsi rester affichée sans bloquer les réponses des apps ni les réouvertures.
        NSTimer *suivant = [NSTimer timerWithTimeInterval:0.0 repeats:NO block:^(NSTimer *minuteur) {
            @try {
                AppuiRecu();
            } @catch (NSException *exception) {
                Journal(@"erreur inattendue : %@", exception);
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:suivant forMode:NSRunLoopCommonModes];
    }
    return noErr;
}

static OSStatus EnregistrerLeRaccourci(void) {
    EventTypeSpec type = { kEventClassKeyboard, kEventHotKeyPressed };
    OSStatus etat = InstallEventHandler(GetApplicationEventTarget(), NewEventHandlerUPP(GestionnaireDeRaccourci),
                                        1, &type, NULL, NULL);
    if (etat != noErr) return etat;
    EventHotKeyID identifiant;
    identifiant.signature = kSignatureDuRaccourci;
    identifiant.id = 1;
    static EventHotKeyRef reference = NULL;
    return RegisterEventHotKey(kTouche, kModificateurs, identifiant, GetApplicationEventTarget(), 0, &reference);
}

// ---------------------------------------------------------------------------------------
// Démarrage
// ---------------------------------------------------------------------------------------

static void Preparer(void) {
    gRelances = [NSMutableDictionary dictionary];
    gRouvertes = [NSMutableDictionary dictionary];
    NSFileManager *fichiers = [NSFileManager defaultManager];
    NSString *dossier = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Relancer"];
    [fichiers createDirectoryAtPath:dossier withIntermediateDirectories:YES attributes:nil error:NULL];
    gJournal = [dossier stringByAppendingPathComponent:@"Relancer.log"];
    // Un journal devenu trop gros repart de zéro.
    NSDictionary *attributs = [fichiers attributesOfItemAtPath:gJournal error:NULL];
    if (attributs != nil && [attributs fileSize] > 512 * 1024) {
        [fichiers removeItemAtPath:gJournal error:NULL];
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Preparer();

        // Note chaque changement de bureau (voir « SurveillerLaFin »).
        gObservateurDEspace = [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        gChangementDEspace = Maintenant();
                    }];

        // Mode d'essai, pour l'installateur : « Relancer --essai <pid> » relance l'app qui a
        // ce numéro de processus, sans la mettre au premier plan, puis s'arrête. Avec le mot
        // « question » en plus, un second appui est simulé un peu plus de trois secondes après
        // le premier : la fenêtre « forcer à quitter » doit alors s'afficher, puis se refermer
        // toute seule quand l'app se ferme.
        if ((argc == 3 || argc == 4) && strcmp(argv[1], "--essai") == 0) {
            gEssai = YES;
            BOOL question = (argc == 4 && strcmp(argv[3], "question") == 0);
            pid_t pid = (pid_t)atoi(argv[2]);
            // L'app vient peut-être tout juste de s'ouvrir : macOS a jusqu'à 5 secondes pour la connaître.
            NSRunningApplication *app = nil;
            for (int tour = 0; tour < 50 && app == nil; tour++) {
                app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                if (app == nil) usleep(100000);
            }
            if (app == nil) {
                printf("essai : aucune application n'a le numéro de processus %d\n", (int)pid);
                return 2;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                LancerRelance(app);
                if (question) {
                    // Le second appui passe par un minuteur, comme un vrai appui.
                    NSTimer *second = [NSTimer timerWithTimeInterval:kAvantDeForcer + 0.3 repeats:NO block:^(NSTimer *m) {
                        Relance *r = gRelances[@(pid)];
                        if (r != nil) {
                            AppuiSuivant(r);
                        } else {
                            Journal(@"essai : l'app était déjà fermée au moment du second appui");
                        }
                    }];
                    [[NSRunLoop mainRunLoop] addTimer:second forMode:NSRunLoopCommonModes];
                }
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                Journal(@"essai : toujours pas terminé après 90 s, j'arrête");
                exit(3);
            });
            [application run];
            return 0;
        }

        // Une seule copie à la fois.
        NSString *moi = [[NSBundle mainBundle] bundleIdentifier];
        if (moi != nil) {
            for (NSRunningApplication *autre in [NSRunningApplication runningApplicationsWithBundleIdentifier:moi]) {
                if (autre.processIdentifier != getpid() && !autre.terminated) {
                    Journal(@"Relancer tourne déjà (pid %d) : cette copie s'arrête", (int)autre.processIdentifier);
                    return 0;
                }
            }
        }

        // Empêche macOS de ralentir ce programme quand il est inactif : il doit réagir tout de suite.
        gActivite = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                   reason:@"Relance des applications"];

        OSStatus etat = EnregistrerLeRaccourci();
        if (etat != noErr) {
            Journal(@"impossible d'enregistrer %@ (erreur %d) : Relancer s'arrête", kToucheLisible, (int)etat);
            return 0;
        }
        Journal(@"prêt : %@ relance l'application au premier plan (version %@, pid %d)",
                kToucheLisible, kVersionDeRelancer, (int)getpid());
        [application run];
    }
    return 0;
}
