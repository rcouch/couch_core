all: check

check: clean reltest
	@./test/couch_dev/bin/test_js

reltest: deps reltestclean
	rebar -C rebar_dev.config compile generate

deps:
	rebar -C rebar_dev.config get-deps

clean:
	rebar clean

reltestclean:
	rm -rf test/couch_dev

.PHONY: deps
