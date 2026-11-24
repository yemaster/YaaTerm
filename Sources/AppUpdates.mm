#import "AppUpdates.h"

SPUStandardUpdaterController *AppUpdateController(void) {
    static SPUStandardUpdaterController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"Sparkle.framework"];
        if (!url || ![[NSBundle bundleWithURL:url] loadAndReturnError:NULL]) return;
        Class type = NSClassFromString(@"SPUStandardUpdaterController");
        controller = [[type alloc] initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];
    });
    return controller;
}

void StartAutomaticUpdatesIfEnabled(void) {
    NSNumber *enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"SUEnableAutomaticChecks"] ?:
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"SUEnableAutomaticChecks"];
    if (enabled.boolValue) AppUpdateController();
}
