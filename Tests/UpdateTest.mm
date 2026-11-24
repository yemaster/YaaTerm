#import "AppUpdates.h"
#import "SettingsView.h"
#include <cassert>
#include <cstdio>

static NSView *findView(NSView *parent, NSString *identifier) {
    if ([parent.identifier isEqualToString:identifier]) return parent;
    for (NSView *child in parent.subviews)
        if (NSView *match = findView(child,identifier)) return match;
    return nil;
}

int main() {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        assert([bundle.bundleIdentifier isEqualToString:@"dev.yaaterm.tests.update"]);
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:NO forKey:@"SUEnableAutomaticChecks"];
        StartAutomaticUpdatesIfEnabled();
        assert(!NSClassFromString(@"SPUStandardUpdaterController"));
        SettingsView *view = [[SettingsView alloc] initWithFrame:NSMakeRect(0,0,780,540)];
        [view selectSection:AboutSection];
        SPUUpdater *updater = AppUpdateController().updater;
        assert(updater && updater.canCheckForUpdates && !updater.automaticallyChecksForUpdates);
        NSButton *check = (NSButton *)findView(view,@"CheckNow");
        assert(check.enabled && check.target == AppUpdateController());
        NSSwitch *install = (NSSwitch *)findView(view,@"AutoInstall");
        assert(install && !install.enabled);
        updater.automaticallyChecksForUpdates = YES;
        assert(install.enabled && [(NSSwitch *)findView(view,@"AutoCheck") state] == NSControlStateValueOn);
        updater.automaticallyChecksForUpdates = NO;
        assert(!install.enabled);
        NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        assert([[(NSTextField *)findView(view,@"AppVersion") stringValue] containsString:version]);
        assert([bundle URLForResource:version withExtension:@"txt" subdirectory:@"ReleaseNotes"]);
        assert(findView(view,@"Feedback") && findView(view,@"ReleaseNotes") && findView(view,@"Repository"));
        [view selectSection:GeneralSection];
        [defaults removePersistentDomainForName:bundle.bundleIdentifier];
        puts("About page, bundled Sparkle, offline notes and automatic update controls OK");
    }
}
