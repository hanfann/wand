.PHONY: build release install test showcase e2e e2e-watch clean stop

build:
	swift build

release:
	swift build -c release

test:
	swift test

install:
	./install.sh

# Build + launch the native SwiftUI showcase on the booted simulator.
showcase:
	./examples/native/build.sh

# Run the end-to-end gesture regression suite against the native showcase.
e2e: build
	chmod +x examples/native/e2e.sh
	./examples/native/e2e.sh

# watchOS regression: scroll, Digital Crown, fail-loud guard (needs a booted watch).
e2e-watch: build
	chmod +x examples/watch/e2e.sh
	./examples/watch/e2e.sh

stop:
	-./.build/debug/wand stop

clean:
	swift package clean
	rm -rf examples/native/build
