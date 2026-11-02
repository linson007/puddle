.PHONY: build run demo test verify-premodel verify-local

build:
	sh scripts/build.sh

run: build
	open build/Puddle.app

demo: build
	open -n build/Puddle.app --args --demo

test:
	sh scripts/swift.sh test

verify-premodel:
	sh scripts/verify-premodel.sh

verify-local:
	python3 scripts/verify-local.py
