.PHONY: build run demo test

build:
	sh scripts/build.sh

run: build
	open build/Puddle.app

demo: build
	open -n build/Puddle.app --args --demo

test:
	sh scripts/swift.sh test
