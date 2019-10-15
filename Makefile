.PHONY: build run clean

run: build
	./_build/default/src/main.exe

build:
	dune build @all

clean:
	dune clean
