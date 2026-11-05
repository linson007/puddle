.PHONY: build run demo test verify guards verify-premodel verify-local

build:
	sh scripts/build.sh

run: build
	open build/Puddle.app

demo: build
	open -n build/Puddle.app --args --demo

test:
	sh scripts/swift.sh test

guards:
	python3 scripts/localizations.py --check
	python3 -m unittest discover -s scripts -p 'test_*.py'
	python3 scripts/check-concurrency.py

verify: guards test

verify-premodel:
	sh scripts/verify-premodel.sh

verify-local:
	python3 scripts/verify-local.py
