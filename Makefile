ERLC ?= erlc


all: check

compile:
	rebar -C rebar_dev.config compile

check: clean reltest js

reltest: deps reltestclean compile
	rebar -C rebar_dev.config generate

js:
	./test/couch_dev/bin/test_js

etap:
	@$(ERLC) -o test/couch_dev/test/etap/ test/files/test_util.erl
	./test/couch_dev/bin/test_etap


deps:
	rebar -C rebar_dev.config get-deps

clean:
	rebar clean

reltestclean:
	rm -rf test/couch_dev

.PHONY: deps
