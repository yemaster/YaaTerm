APP := build/YaaTerm.app
BIN := $(APP)/Contents/MacOS/YaaTerm
CXX := xcrun clang++
FLAGS := -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0
SPARKLE := build/dependencies/sparkle-2.10.1
GRID := Sources/Emoji.cpp Sources/Screen.cpp Sources/History.cpp
GRID_HEADERS := Sources/Emoji.hpp Sources/EmojiData.inc Sources/Screen.hpp Sources/History.hpp Sources/TerminalRow.hpp
ASSISTANT := Sources/TerminalAssistant.mm Sources/LLMConfiguration.mm
SOURCES := $(ASSISTANT) Sources/AppUpdates.mm Sources/Main.mm Sources/TaskNotices.mm Sources/LLMSettingsForm.mm Sources/Wallpaper.mm Sources/WindowContent.mm Sources/TabBar.mm Sources/TabWorkspace.mm Sources/TerminalView.mm Sources/TerminalOutput.mm Sources/FindBar.mm Sources/Session.mm $(GRID) Sources/TerminalSearch.cpp Sources/Preferences.mm Sources/Shortcuts.mm Sources/Palette.mm Sources/SettingsView.mm
UPDATE_TEST := build/tests/UpdateTest.app/Contents/MacOS/YaaTerm
OUTPUT_TEST := build/tests/output/output-test
HIGHLIGHT_TEST := build/tests/HighlightTest.app/Contents/MacOS/YaaTerm
SHELL_RESOURCES := $(shell find Resources/Shell -type f)
.PHONY: all run test
all: $(BIN)

$(SPARKLE)/.ready: scripts/fetch-sparkle.sh
	sh $<

$(APP)/Contents/Helpers/yaa-inspect: Sources/Inspect.mm Makefile
	mkdir -p $(@D)
	$(CXX) $(FLAGS) $(ARCH_FLAGS) -fobjc-arc $< -framework Foundation -o $@
	codesign --force --sign - $@

$(BIN): $(APP)/Contents/Helpers/yaa-inspect $(SPARKLE)/.ready $(SOURCES) $(wildcard Sources/*.h Sources/*.hpp Sources/*.inc) Makefile Info.plist Resources/Unicode-LICENSE.txt Resources/YaaTerm.icns Resources/ThemeCredits.txt $(wildcard Resources/ReleaseNotes/*.txt) $(wildcard Resources/Fonts/*) $(SHELL_RESOURCES)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/
	rsync -a --delete --exclude=.DS_Store Resources/ $(APP)/Contents/Resources/
	mkdir -p $(APP)/Contents/Frameworks
	ditto $(SPARKLE)/Sparkle.framework $(APP)/Contents/Frameworks/Sparkle.framework
	cp $(SPARKLE)/LICENSE $(APP)/Contents/Resources/Sparkle-LICENSE.txt
	$(CXX) $(FLAGS) $(ARCH_FLAGS) -F$(SPARKLE) -lcompression -fobjc-arc $(SOURCES) -framework AppKit -framework Foundation -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security -o $@
	codesign --force --sign - $(APP)
	touch $(APP)

run: all
	open $(APP)

test: build/llm-test build/screen-test build/vim-test build/session-test build/selection-test build/tab-test $(HIGHLIGHT_TEST) $(OUTPUT_TEST) $(UPDATE_TEST)
	./build/llm-test
	./build/screen-test
	./build/vim-test
	./build/session-test
	./build/selection-test
	./build/tab-test
	./$(HIGHLIGHT_TEST)
	./$(OUTPUT_TEST)
	./$(UPDATE_TEST)

build/screen-test: Tests/ScreenTest.cpp $(GRID) Sources/TerminalSearch.cpp $(GRID_HEADERS) Sources/TerminalSearch.hpp
	mkdir -p build
	$(CXX) $(FLAGS) -lcompression -ISources Tests/ScreenTest.cpp $(GRID) Sources/TerminalSearch.cpp -o $@


build/session-test: Tests/SessionTest.mm Sources/Session.mm Sources/Session.h
	mkdir -p build
	$(CXX) $(FLAGS) -fobjc-arc -ISources Tests/SessionTest.mm Sources/Session.mm -framework Foundation -framework AppKit -o $@

build/selection-test: $(ASSISTANT) Tests/SelectionTest.mm Sources/Wallpaper.mm Sources/TerminalView.mm Sources/TerminalOutput.mm Sources/FindBar.mm Sources/Palette.mm Sources/Preferences.mm Sources/Shortcuts.mm Sources/Session.mm $(GRID) Sources/TerminalSearch.cpp $(wildcard Sources/*.h Sources/*.hpp Sources/*.inc)
	mkdir -p build
	$(CXX) $(FLAGS) -lcompression -fobjc-arc -ISources $(filter %.mm %.cpp,$^) -framework AppKit -framework CoreGraphics -framework CoreText -framework Security -framework ImageIO -framework QuartzCore -o $@

$(OUTPUT_TEST): $(ASSISTANT) Tests/OutputTest.mm Sources/Session.mm Sources/TerminalView.mm Sources/TerminalOutput.mm Sources/FindBar.mm Sources/Wallpaper.mm Sources/Palette.mm Sources/Preferences.mm Sources/Shortcuts.mm Sources/TerminalSearch.cpp $(GRID) $(wildcard Sources/*.h Sources/*.hpp Sources/*.inc) $(BIN)
	mkdir -p $(@D)
	ln -sfn "$(abspath $(APP))/Contents/Resources/Shell" $(@D)/Shell
	$(CXX) $(FLAGS) -lcompression -fobjc-arc -ISources $(filter %.mm %.cpp,$^) -framework AppKit -framework CoreText -framework QuartzCore -framework Security -framework ImageIO -o $@

$(HIGHLIGHT_TEST): Tests/HighlightTest.mm Sources/Session.mm Sources/Session.h $(GRID) $(GRID_HEADERS) $(BIN)
	mkdir -p $(@D)
	cp $(APP)/Contents/Info.plist $(@D)/../
	plutil -replace CFBundleIdentifier -string dev.yaaterm.tests.highlight $(@D)/../Info.plist
	plutil -replace CFBundleName -string HighlightTest $(@D)/../Info.plist
	ln -sfn "$(abspath $(APP))/Contents/Resources" $(@D)/../Resources
	$(CXX) $(FLAGS) -lcompression -fobjc-arc -ISources Tests/HighlightTest.mm Sources/Session.mm $(GRID) -framework AppKit -o $@

build/tab-test: $(SPARKLE)/.ready Tests/TabTest.mm $(filter-out Sources/Main.mm,$(SOURCES)) $(wildcard Sources/*.h Sources/*.hpp Sources/*.inc)
	mkdir -p build
	$(CXX) $(FLAGS) -F$(SPARKLE) -lcompression -fobjc-arc -ISources $(filter %.mm %.cpp,$^) -framework AppKit -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers -framework Security -o $@

build/llm-test: $(SPARKLE)/.ready Sources/TerminalAssistant.mm Sources/AppUpdates.mm Tests/LLMTest.mm Sources/LLMConfiguration.mm Sources/LLMSettingsForm.mm Sources/SettingsView.mm Sources/Wallpaper.mm Sources/Palette.mm Sources/Preferences.mm Sources/Shortcuts.mm $(wildcard Sources/*.h Sources/*.hpp Sources/*.inc)
	mkdir -p build
	$(CXX) $(FLAGS) -F$(SPARKLE) -fobjc-arc -ISources -DSecItemCopyMatching=LLMTestCopyMatching -DSecItemDelete=LLMTestDelete -DSecKeychainGetUserInteractionAllowed=LLMTestGetInteraction -DSecKeychainSetUserInteractionAllowed=LLMTestSetInteraction $(filter %.mm,$^) -framework AppKit -framework UniformTypeIdentifiers -framework ImageIO -framework Security -o $@

build/vim-test: Tests/VimTest.mm Sources/Session.mm $(GRID) $(GRID_HEADERS) Sources/Session.h
	mkdir -p build
	$(CXX) $(FLAGS) -lcompression -fobjc-arc -ISources $(filter %.mm %.cpp,$^) -framework AppKit -o $@

$(UPDATE_TEST): Tests/UpdateTest.mm Sources/AppUpdates.mm Sources/SettingsView.mm Sources/LLMSettingsForm.mm Sources/LLMConfiguration.mm Sources/Wallpaper.mm Sources/Palette.mm Sources/Preferences.mm Sources/Shortcuts.mm $(wildcard Sources/*.h Sources/*.hpp Sources/*.inc) $(BIN)
	mkdir -p $(@D)
	cp Info.plist $(@D)/../
	plutil -replace CFBundleIdentifier -string dev.yaaterm.tests.update $(@D)/../Info.plist
	plutil -insert LSBackgroundOnly -bool YES $(@D)/../Info.plist
	ln -sfn "$(abspath $(APP))/Contents/Resources" $(@D)/../Resources
	ln -sfn "$(abspath $(APP))/Contents/Frameworks" $(@D)/../Frameworks
	$(CXX) $(FLAGS) -F$(SPARKLE) -fobjc-arc -ISources $(filter %.mm,$^) -framework AppKit -framework UniformTypeIdentifiers -framework ImageIO -framework Security -o $@

.PHONY: sign-release
sign-release: $(SPARKLE)/.ready
	node scripts/sign-release.mjs $(SPARKLE)/bin/sign_update build/release
