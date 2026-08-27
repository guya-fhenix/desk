APP_NAME = Fhenix Desk
BUILD_DIR = build
APP = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build test run doctor app install clean

build:
	swift build

test:
	swift test

run:
	swift run FhenixDesk

doctor:
	swift run FhenixDesk --doctor

app:
	scripts/bundle.sh

install: app
	rm -rf "$(HOME)/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "$(HOME)/Applications/"
	open "$(HOME)/Applications/$(APP_NAME).app"

clean:
	rm -rf .build $(BUILD_DIR)
