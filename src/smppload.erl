-module(smppload).

-export([
    main/0,
    main/1
]).

-include("message.hrl").
-include("smppload.hrl").
-include_lib("oserl/include/smpp_globals.hrl").

%% ===================================================================
%% API
%% ===================================================================

-spec main() -> no_return().
main() ->
    PlainArgs = init:get_plain_arguments(),
    case PlainArgs of
        ["--", Args] ->
            main(Args);
        _ ->
            main([])
    end.

-spec main([string()]) -> no_return().
main([]) ->
    AppName = app_name(),
    OptSpecs = opt_specs(),
    print_usage(AppName, OptSpecs);
main("--") ->
    main([]);
main(Args) ->
    AppName = app_name(),
    OptSpecs = opt_specs(),

    case getopt:parse(OptSpecs, Args) of
        {ok, {Opts, _NonOptArgs}} ->
            process_opts(AppName, Opts, OptSpecs);
        {error, {Reason, Data}} ->
            ?ABORT("Parse data ~p failed with: ~s~n", [Data, Reason])
    end.

%% ===================================================================
%% Internal
%% ===================================================================

opt_specs() ->
    DC = ?ENCODING_SCHEME_LATIN_1,
    {MaxMsgLen, _} = smppload_utils:max_msg_seg(DC),
    [
        %% {Name, ShortOpt, LongOpt, ArgSpec, HelpMsg}
        {help, $h, "help", undefined, "Show this message"},
        {host, $H, "host", {string, "127.0.0.1"}, "SMSC server host name or IP address"},
        {port, $P, "port", {integer, 2775}, "SMSC server port"},
        {bind_type, $B, "bind_type", {string, "trx"}, "SMSC bind type: tx | trx"},
        {system_id, $i, "system_id", {string, "user"}, "SMSC system_id"},
        {password, $p, "password", {string, "password"}, "SMSC password"},
        {system_type, $t, "system_type", {string, ""}, "SMSC service_type"},
        {rps, $r, "rps", {integer, 1000}, "Number of requests per second"},
        {source, $s, "source", {string, ""}, "SMS source address Addr[:Len][,Ton=1,Npi=1]"},
        {destination , $d, "destination", {string, ""}, "SMS destination address Addr[:Len][,Ton=1,Npi=1]"},
        {body, $b, "body", string, "SMS body, randomly generated by default"},
        {length, $l, "length", {integer, MaxMsgLen}, "Randomly generated body length"},
        {count, $c, "count", {integer, 1}, "Count of SMS to send with given or random body"},
        {delivery, $D, "delivery", {integer, 0}, "Delivery receipt"},
        {data_coding, $C, "data_coding", {integer, DC}, "Data coding"},
        {file, $f, "file", string, "Send messages from file"},
        {verbosity, $v, "verbosity", {integer, 1}, "Verbosity level"},
        {thread_count, $T, "thread_count", {integer, 10}, "Thread/process count"},
        {bind_timeout, undefined, "bind_timeout", {integer, 10}, "Bind timeout, sec"},
        {unbind_timeout, undefined, "unbind_timeout", {integer, 5}, "Unbind timeout, sec"},
        {submit_timeout, undefined, "submit_timeout", {integer, 20}, "Submit timeout, sec"},
        {delivery_timeout, undefined, "delivery_timeout", {integer, 80}, "Delivery timeout, sec"}
    ].

process_opts(AppName, Opts, OptSpecs) ->
    case ?gv(help, Opts, false) of
        true ->
            print_usage(AppName, OptSpecs);
        false ->
            %% initialize the logger.
            smppload_log:init(?gv(verbosity, Opts)),
            ?DEBUG("Options: ~p~n", [Opts]),

            BindTypeFun = get_bind_type_fun(Opts),
            ?DEBUG("BindTypeFun: ~p~n", [BindTypeFun]),

            MessagesModule = get_lazy_messages_module(Opts),
            ?DEBUG("MessagesModule: ~p~n", [MessagesModule]),

            %% start needed applications.
            error_logger:tty(false),
            application:start(common_lib),
            application:start(smppload),

            {ok, _} = smppload_esme:start(),

            Host = ?gv(host, Opts),
            Port = ?gv(port, Opts),
            Peer = format_peer(Host, Port),
            case smppload_esme:connect(Host, Port) of
                ok ->
                    ?INFO("Connected to ~s~n", [Peer]);
                {error, Reason1} ->
                    ?ABORT("Connect to ~s failed with: ~s~n", [Peer, Reason1])
            end,

            SystemType = ?gv(system_type, Opts),
            SystemId = ?gv(system_id, Opts),
            Password = ?gv(password, Opts),
            BindTimeout = ?gv(bind_timeout, Opts) * 1000,
            BindParams = [
                {system_type, SystemType},
                {system_id, SystemId},
                {password, Password},
                {bind_timeout, BindTimeout}
            ],
            case apply(smppload_esme, BindTypeFun, [BindParams]) of
                {ok, RemoteSystemId} ->
                    ?INFO("Bound to ~s~n", [RemoteSystemId]);
                {error, Reason2} ->
                    ?ABORT("Bind failed with: ~p~n", [Reason2])
            end,

            Rps = ?gv(rps, Opts),
            ok = smppload_esme:set_max_rps(Rps),

            {ok, Stats} = send_messages(MessagesModule, Opts),

            ?INFO("Stats:~n", []),
            ?INFO("   Send success:     ~p~n", [smppload_stats:send_succ(Stats)]),
            ?INFO("   Delivery success: ~p~n", [smppload_stats:dlr_succ(Stats)]),
            ?INFO("   Send fail:        ~p~n", [smppload_stats:send_fail(Stats)]),
            ?INFO("   Delivery fail:    ~p~n", [smppload_stats:dlr_fail(Stats)]),
            ?INFO("   Errors:           ~p~n", [smppload_stats:errors(Stats)]),
            ?INFO("   Avg Rps:          ~p mps~n", [smppload_stats:rps(Stats)]),

            UnbindTimeout = ?gv(unbind_timeout, Opts) * 1000,
            UnbindParams = [
                {unbind_timeout, UnbindTimeout}
            ],
            smppload_esme:unbind(UnbindParams),
            ?INFO("Unbound~n", []),

            %% stop applications.
            error_logger:tty(false),
            application:stop(smppload),
            application:stop(common_lib)
    end.

format_peer({A, B, C, D}, Port) ->
    io_lib:format("~p.~p.~p.~p:~p", [A, B, C, D, Port]);
format_peer(Host, Port) when is_list(Host) ->
    io_lib:format("~s:~p", [Host, Port]).

get_bind_type_fun(Opts) ->
    BindType = ?gv(bind_type, Opts),
    case string:to_lower(BindType) of
        "tx" ->
            bind_transmitter;
        "trx" ->
            bind_transceiver;
        _ ->
            ?ABORT("Unknown bind type: ~p~n", [BindType])
    end.

get_lazy_messages_module(Opts) ->
    case ?gv(file, Opts) of
        undefined ->
            case ?gv(body, Opts) of
                undefined ->
                    check_destination(Opts),
                    smppload_lazy_messages_random;
                _ ->
                    check_destination(Opts),
                    smppload_lazy_messages_body
            end;
        _ ->
            smppload_lazy_messages_file
    end.

check_destination(Opts) ->
    case ?gv(destination, Opts) of
        [] ->
            case ?gv(count, Opts) of
                0 ->
                    ok;
                _ ->
                    ?ABORT("Destination address is not provided~n", [])
            end;
        _ ->
            ok
    end.

send_messages(Module, Opts) ->
    {ok, State0} = smppload_lazy_messages:init(Module, Opts),
    {ok, State1, Stats} = send_parallel_messages(State0, Opts),
    ok = smppload_lazy_messages:deinit(State1),
    {ok, Stats}.

send_parallel_messages(State0, Opts) ->
    process_flag(trap_exit, true),
    ReplyTo = self(),
    ReplyRef = make_ref(),
    ThreadCount = ?gv(thread_count, Opts),
    {ok, MsgSent, State1} = send_parallel_init_messages(
        ReplyTo, ReplyRef, Opts, ThreadCount, 0, State0
    ),
    send_parallel_messages_and_collect_replies(
        ReplyTo, ReplyRef, Opts,
        MsgSent, State1, smppload_stats:new()
    ).

%% start phase
send_parallel_init_messages(_ReplyTo, _ReplyRef, _Opts, MaxMsgCnt, MaxMsgCnt, State0) ->
    {ok, MaxMsgCnt, State0};
send_parallel_init_messages(ReplyTo, ReplyRef, Opts, MaxMsgCnt, MsgCnt, State0) ->
    case smppload_lazy_messages:get_next(State0) of
        {ok, Submit, State1} ->
            spawn_link(
                fun() ->
                    SubmitTimeout = ?gv(submit_timeout, Opts) * 1000,
                    DeliveryTimeout = ?gv(delivery_timeout, Opts) * 1000,
                    send_message_and_reply(ReplyTo, ReplyRef, Submit, SubmitTimeout, DeliveryTimeout)
                end
            ),
            send_parallel_init_messages(
                ReplyTo, ReplyRef, Opts, MaxMsgCnt, MsgCnt + 1, State1
            );
        {no_more, State1} ->
            {ok, MsgCnt, State1}
    end.

%% collect and send new messages phase.
send_parallel_messages_and_collect_replies(
    _ReplyTo, _ReplyRef, _Opts, 0, State0, Stats0
) ->
    Stats1 =
        case smppload_esme:get_avg_rps() of
            {ok, AvgRps} ->
                smppload_stats:inc_rps(Stats0, AvgRps);
            {error, _} ->
                Stats0
        end,
    {ok, State0, Stats1};
send_parallel_messages_and_collect_replies(
    ReplyTo, ReplyRef, Opts, MsgSent, State0, Stats0
) ->
    SubmitTimeout = ?gv(submit_timeout, Opts) * 1000,
    DeliveryTimeout = ?gv(delivery_timeout, Opts) * 1000,
    Timeout =
        case ?gv(delivery, Opts, 0) of
            0 ->
                SubmitTimeout + 1000;
            _ ->
                SubmitTimeout + DeliveryTimeout + 1000
        end,
    receive
        {ReplyRef, Stats} ->
            send_parallel_messages_and_collect_replies(
                ReplyTo, ReplyRef, Opts,
                MsgSent - 1 + 1, State0, smppload_stats:add(Stats0, Stats)
            );

        {'EXIT', _Pid, Reason} ->
            Stats1 =
                case Reason of
                    normal ->
                        Stats0;
                    _Other ->
                        ?ERROR("Submit failed with: ~p~n", [Reason]),
                        smppload_stats:inc_errors(Stats0)
                end,
            case smppload_lazy_messages:get_next(State0) of
                {ok, Submit, State1} ->
                    spawn_link(
                        fun() ->
                            send_message_and_reply(ReplyTo, ReplyRef, Submit,
                                SubmitTimeout, DeliveryTimeout)
                        end
                    ),
                    send_parallel_messages_and_collect_replies(
                        ReplyTo, ReplyRef, Opts,
                        MsgSent - 1 + 1, State1, Stats1
                    );
                {no_more, State1} ->
                    send_parallel_messages_and_collect_replies(
                        ReplyTo, ReplyRef, Opts,
                        MsgSent - 1, State1, Stats1
                    )
            end
    after
        Timeout ->
            ?ERROR("Timeout~n", []),
            Stats1 =
                case smppload_esme:get_avg_rps() of
                    {ok, AvgRps} ->
                        smppload_stats:inc_rps(
                            smppload_stats:inc_errors(
                                smppload_stats:inc_send_fail(Stats0, MsgSent), MsgSent), AvgRps);
                    {error, _} ->
                        smppload_stats:inc_errors(
                            smppload_stats:inc_send_fail(Stats0, MsgSent), MsgSent)
                end,
            {ok, State0, Stats1}
    end.

send_message_and_reply(ReplyTo, ReplyRef, Submit, SubmitTimeout, DeliveryTimeout) ->
    Stats = send_message(Submit, SubmitTimeout, DeliveryTimeout),
    ReplyTo ! {ReplyRef, Stats}.

send_message(Msg, SubmitTimeout, DeliveryTimeout) ->
    SourceAddr =
        case Msg#message.source of
            [] ->
                [];
            _ ->
                [
                    {source_addr_ton , Msg#message.source#address.ton},
                    {source_addr_npi , Msg#message.source#address.npi},
                    {source_addr     , Msg#message.source#address.addr}
                ]
        end,
    RegDlr =
        case Msg#message.delivery of
            true  ->
                1;
            false ->
                0;
            Int when is_integer(Int), Int > 0 ->
                1;
            _Other ->
                0
        end,
    Params = SourceAddr ++ [
        {dest_addr_ton      , Msg#message.destination#address.ton},
        {dest_addr_npi      , Msg#message.destination#address.npi},
        {destination_addr   , Msg#message.destination#address.addr},
        {short_message      , Msg#message.body},
        {esm_class          , Msg#message.esm_class},
        {data_coding        , Msg#message.data_coding},
        {registered_delivery, RegDlr},
        {submit_timeout     , SubmitTimeout},
        {delivery_timeout   , DeliveryTimeout}
    ],

    case smppload_esme:submit_sm(Params) of
        {ok, _OutMsgId, no_delivery} ->
            smppload_stats:inc_send_succ(smppload_stats:new());
        {ok, _OutMsgId, delivery_timeout} ->
            smppload_stats:inc_dlr_fail(smppload_stats:inc_send_succ(smppload_stats:new()));
        {ok, _OutMsgId, _DlrRes} ->
            smppload_stats:inc_dlr_succ(smppload_stats:inc_send_succ(smppload_stats:new()));
        {error, _Reason} ->
            smppload_stats:inc_send_fail(smppload_stats:new())
    end.

print_usage(AppName, OptSpecs) ->
    print_description_vsn(AppName),
    getopt:usage(OptSpecs, AppName).

print_description_vsn(AppName) ->
    case description_vsn(AppName) of
        {Description, Vsn} ->
            io:format("~s (~s)~n", [Description, Vsn]);
        _ ->
            ok
    end.

description_vsn(AppName) ->
    case app_options(AppName) of
        undefined ->
            undefined;
        Options ->
            Description = ?gv(description, Options),
            Vsn = ?gv(vsn, Options),
            {Description, Vsn}
    end.

is_escript() ->
    case init:get_argument(mode) of
        {ok, [["embedded"]]} ->
            false;
        _ ->
            true
    end.

app_name() ->
    case is_escript() of
        true ->
            escript:script_name();
        false ->
            {ok, [[AppName]]} = init:get_argument(progname),
            AppName
    end.

app_options(AppName) ->
    case is_escript() of
        true ->
            escript_options(AppName);
        false ->
            application_options(AppName)
    end.

escript_options(ScriptName) ->
    {ok, Sections} = escript:extract(ScriptName, []),
    Zip = ?gv(archive, Sections),
    AppName = lists:flatten(io_lib:format("~p.app", [?MODULE])),
    case zip:extract(Zip, [{file_list, [AppName]}, memory]) of
        {ok, [{AppName, Binary}]} ->
            {ok, Tokens, _} = erl_scan:string(binary_to_list(Binary)),
            {ok, {application, ?MODULE, Options}} = erl_parse:parse_term(Tokens),
            Options;
        _ ->
            undefined
    end.

application_options(_AppName) ->
    case application:get_all_key(?MODULE) of
        undefined ->
            undefined;
        {ok, Options} ->
            Options
    end.
