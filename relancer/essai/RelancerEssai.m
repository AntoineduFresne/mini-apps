//
//  App d'essai de Relancer. L'installateur s'en sert pour vérifier, sur ton Mac, que chaque
//  façon de quitter est bien gérée, puis il la supprime. Elle imite, selon le mot reçu au
//  lancement :
//
//    (rien)    une app Electron (VS Code, Slack) : elle répond « annulé » à la demande de
//              fermeture, puis se ferme d'elle-même une seconde et demie plus tard ;
//    retrait   WhatsApp : elle retire sa fenêtre de l'écran, se retire du Dock, et garde son
//              processus en vie 20 secondes. Elle garde exprès une fenêtre hors de l'écran et
//              en crée une autre : seul son retrait du Dock montre alors qu'elle a quitté ;
//    fenetres  Mail : elle ferme sa fenêtre et garde son processus en vie 20 secondes ;
//    gardees   la même chose, mais la fenêtre est seulement retirée de l'écran ;
//    dialogue  une app qui affiche un dialogue d'enregistrement : sa fenêtre reste à l'écran,
//              et elle ne quitte que 4 secondes plus tard ;
//    cache     la même chose, mais le dialogue se trouve hors de l'écran, comme s'il était
//              sur un autre bureau ;
//    question  comme « dialogue », mais elle ne quitte que 5 secondes plus tard : le temps
//              pour Relancer d'afficher sa fenêtre « forcer à quitter » après un second appui.
//
//  Dans les quatre premiers cas, Relancer doit rouvrir l'app rapidement. Dans les trois
//  derniers, il ne doit surtout pas l'arrêter : il attend qu'elle quitte d'elle-même.
//

#import <Cocoa/Cocoa.h>

static NSString *gMode = @"";
static NSWindow *gFenetre;       // la fenêtre montrée au lancement
static NSWindow *gDialogue;      // la fenêtre hors de l'écran des modes « cache » et « retrait »

static NSWindow *NouvelleFenetre(NSString *titre) {
    NSWindow *fenetre = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 110)
                                                    styleMask:NSWindowStyleMaskTitled
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    fenetre.releasedWhenClosed = NO;
    fenetre.title = titre;
    [fenetre center];
    return fenetre;
}

// Un minuteur inscrit dans tous les modes courants : il se déclenche aussi pendant que
// l'app attend, fenêtre de dialogue ouverte ou fermeture en cours.
static void QuitterDans(double secondes) {
    NSTimer *minuteur = [NSTimer timerWithTimeInterval:secondes repeats:NO block:^(NSTimer *m) {
        exit(0);
    }];
    [[NSRunLoop mainRunLoop] addTimer:minuteur forMode:NSRunLoopCommonModes];
}

@interface Delegue : NSObject <NSApplicationDelegate>
@end

@implementation Delegue

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if ([gMode isEqualToString:@"dialogue"]) {
        QuitterDans(4.0);
        return NSTerminateLater;
    }
    if ([gMode isEqualToString:@"question"]) {
        QuitterDans(5.0);
        return NSTerminateLater;
    }
    if ([gMode isEqualToString:@"cache"]) {
        [gFenetre close];
        gFenetre = nil;
        // Une fenêtre nouvelle, qui existe mais n'est plus à l'écran.
        gDialogue = NouvelleFenetre(@"Dialogue hors de l'écran");
        [gDialogue orderFrontRegardless];
        [gDialogue orderOut:nil];
        QuitterDans(4.0);
        return NSTerminateLater;
    }
    if ([gMode isEqualToString:@"gardees"]) {
        [gFenetre orderOut:nil];
        QuitterDans(20.0);
        return NSTerminateLater;
    }
    if ([gMode isEqualToString:@"retrait"]) {
        [gFenetre orderOut:nil];
        gDialogue = NouvelleFenetre(@"Fenêtre hors de l'écran");
        [gDialogue orderFrontRegardless];
        [gDialogue orderOut:nil];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        QuitterDans(20.0);
        return NSTerminateLater;
    }
    if ([gMode isEqualToString:@"fenetres"]) {
        [gFenetre close];
        gFenetre = nil;
        QuitterDans(20.0);
        return NSTerminateLater;
    }
    QuitterDans(1.5);
    return NSTerminateCancel;
}

@end

// Variable globale : l'application ne retient pas son délégué, il doit donc rester en vie
// pendant toute la durée du programme.
static Delegue *gDelegue;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2) gMode = [NSString stringWithUTF8String:argv[1]];
        NSApplication *application = [NSApplication sharedApplication];
        gDelegue = [[Delegue alloc] init];
        application.delegate = gDelegue;
        if (gMode.length > 0) {
            // Les modes avec fenêtre : une app ordinaire, présente dans le Dock.
            [application setActivationPolicy:NSApplicationActivationPolicyRegular];
            gFenetre = NouvelleFenetre(@"Essai de Relancer : cette fenêtre se ferme toute seule");
            [gFenetre orderFrontRegardless];
        } else {
            [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        }
        // Garde-fou : l'app d'essai ne reste jamais ouverte plus de deux minutes.
        QuitterDans(120.0);
        [application run];
    }
    return 0;
}
