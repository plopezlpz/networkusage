CONFIGURATION ?= Debug
XCODEBUILD_ARGS ?=

.PHONY: project build test run clean

project:
	xcodegen generate

build: project
	xcodebuild -project NetworkMon.xcodeproj -scheme NetworkMon -configuration $(CONFIGURATION) -derivedDataPath .build $(XCODEBUILD_ARGS) build

test: project
	xcodebuild -project NetworkMon.xcodeproj -scheme NetworkMon -configuration $(CONFIGURATION) -derivedDataPath .build $(XCODEBUILD_ARGS) test

run: build
	open .build/Build/Products/$(CONFIGURATION)/NetworkMon.app

clean:
	rm -rf .build NetworkMon.xcodeproj
