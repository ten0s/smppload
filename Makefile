NAME=smppload
REBAR=./rebar3
OTP_PLT=~/.otp.plt
PRJ_PLT=$(NAME).plt

.PHONY: test

all: rel escriptize

rel: compile
	@rm -rf ./rel/$(NAME)
	@$(REBAR) release

escriptize: compile xref
	@$(REBAR) escriptize

compile: get-deps
	@$(REBAR) compile

xref: compile
	@$(REBAR) xref

get-deps:
	@$(REBAR) get-deps

update-deps:
	@$(REBAR) upgrade

clean:
	@$(REBAR) clean

check: xref

test:
	@$(REBAR) eunit

cover:
	@$(REBAR) cover

dialyze: $(OTP_PLT) compile $(PRJ_PLT)
	@dialyzer --plt $(PRJ_PLT) -r ./subapps/*/ebin

$(OTP_PLT):
	@dialyzer --build_plt --output_plt $(OTP_PLT) --apps erts \
		kernel stdlib crypto mnesia sasl common_test eunit ssl \
		asn1 compiler syntax_tools inets

$(PRJ_PLT):
	@dialyzer --add_to_plt --plt $(OTP_PLT) --output_plt $(PRJ_PLT) \
	-r ./deps/*/ebin ./subapps/*/ebin

console:
	@./_build/default/rel/$(NAME)/bin/$(NAME) console

develop:
	@./_build/default/rel/$(NAME)/bin/$(NAME) develop

tags:
	@find . -name "*.[e,h]rl" -print | etags -
