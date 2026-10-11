.PHONY: build check check-audio run
build:
	bash scripts/build.sh
check:
	bash scripts/check.sh
check-audio:
	bash scripts/check-audio.sh
run: build
	open dist/JARVIS.app
