#import <Sparkle/SPUStandardUpdaterController.h>
#import <Sparkle/SPUUpdater.h>

// Main thread only. Shared across windows and loaded on first use.
SPUStandardUpdaterController *AppUpdateController(void);
void StartAutomaticUpdatesIfEnabled(void);
