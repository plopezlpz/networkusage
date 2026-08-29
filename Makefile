.PHONY: project build test run clean

project:
	xcodegen generate

build: project
	xcodebuild -project NetworkMon.xcodeproj -scheme NetworkMon -configuration Debug -derivedDataPath .build build

test: project
	xcodebuild -project NetworkMon.xcodeproj -scheme NetworkMon -configuration Debug -derivedDataPath .build test

run: build
	open .build/Build/Products/Debug/NetworkMon.app

clean:
	rm -rf .build NetworkMon.xcodeproj
