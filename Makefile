APP := build/Build/Products/Debug/ReadAlong.app

.PHONY: generate build run test clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project ReadAlong.xcodeproj -scheme ReadAlong -configuration Debug -derivedDataPath build build

run: build
	@pkill -x ReadAlong 2>/dev/null || true
	@sleep 0.5
	open "$(APP)"

test: generate
	xcodebuild -project ReadAlong.xcodeproj -scheme ReadAlong -configuration Debug -derivedDataPath build test

clean:
	rm -rf build
