-module(lazy_messages_random_tests).

-include("../src/lazy_messages.hrl").
-include("../src/message.hrl").

-include_lib("eunit/include/eunit.hrl").
-spec test() -> ok | {error, term()}.

%% ===================================================================
%% Tests begin
%% ===================================================================

-spec full_test() -> ok | {error, term()}.
full_test() ->
	Config = [{seed, {1,1,1}}, {source, "s"}, {destination, "d"}, {delivery, true}, {count, 3}, {length, 5}],
	{ok, State0} = lazy_messages_random:init(Config),
	{ok, Msg, State1} = lazy_messages_random:get_next(State0),
	#message{source = Source, destination = Destination, body = Body1, delivery = Delivery} = Msg,
	?assertEqual(#address{addr = "s", ton = 1, npi = 1}, Source),
	?assertEqual(#address{addr = "d", ton = 1, npi = 1}, Destination),
	?assert(Delivery),
	?assertEqual("Plesn", Body1),
	{ok, #message{body = Body2}, State2} = lazy_messages_random:get_next(State1),
	?assertEqual("YPTRt", Body2),
	{ok, #message{body = Body3}, State3} = lazy_messages_random:get_next(State2),
	?assertEqual("4rIYy", Body3),
	{no_more, State4} = lazy_messages_random:get_next(State3),
	ok = lazy_messages_random:deinit(State4).

-spec no_source_test() -> ok | {error, term()}.
no_source_test() ->
	Config = [{destination, "d"}, {body, "b"}, {delivery, true}, {count, 1}],
	{ok, State0} = lazy_messages_body:init(Config),
	{ok, Msg, State1} = lazy_messages_body:get_next(State0),
	#message{source = Source} = Msg,
	?assertEqual(undefined, Source),
	{no_more, State2} = lazy_messages_body:get_next(State1),
	ok = lazy_messages_body:deinit(State2).

%% ===================================================================
%% Tests end
%% ===================================================================
