%% The adapter against a REAL Cowboy server on a real socket, plus the shared
%% conformance corpus asserted end to end rather than against the core.
%%
%% What is NOT here is the condition matrix, fail-open and the selectors: those
%% are framework-independent and are asserted once for Erlang, in the
%% internetdata package's own suite. Repeating them per adapter is how two
%% adapters end up disagreeing about which copy is right.
%%
%% A loopback client makes `cowboy_req:peer/1' a bogon, which is answered
%% locally without a request. Anything that needs a served answer therefore has
%% to arrive wearing a public address, through a selector.
-module(internetdata_cowboy_tests).

-include_lib("eunit/include/eunit.hrl").

%% Cowboy calls init/2 on the handler MODULE, and both the app under test and
%% the stub API are handlers, so one callback serves both and the route's own
%% state says which.
-export([init/2]).

-define(PUBLIC_IP, <<"45.83.91.1">>).

%% The README's first condition.
-define(COUNTRIES, #{location => #{country => [<<"CU">>, <<"IR">>, <<"KP">>]}}).

%%% ---------------------------------------------------------------- the corpus

corpus_conditions_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1,
     {inparallel,
      [{binary_to_list(Name), fun() -> assert_condition(Case) end}
       || #{<<"name">> := Name} = Case <- corpus(<<"conditions">>)]}}.

assert_condition(#{<<"condition">> := Condition, <<"expect">> := Expect, <<"why">> := Why} = Case) ->
    {Ip, Body} = fixture(Case),
    Api = api(Body),
    Warnings = collector(),
    App = app(#{
        base_url => base_url(Api),
        retries => 0,
        ip_selector => fun(_View) -> Ip end,
        block_condition => Condition,
        on_warn => sink(Warnings)
    }),

    {Status, Seen} = get(App, "/", []),

    Want = case maps:get(<<"blocked">>, Expect) of true -> 403; false -> 200 end,
    ?assertEqual({Want, Why}, {Status, Why}),
    %% The status alone passes every case the condition lets through with the
    %% middleware removed, so the handler must also see the answer it attached.
    case Status of
        403 -> ?assertEqual({#{<<"error">> => <<"access denied">>}, Why}, {Seen, Why});
        200 -> ?assertEqual({attached(Case, Ip), Why}, {maps:with(maps:keys(attached(Case, Ip)), Seen), Why})
    end,
    Missing = maps:get(<<"missing">>, Expect, []),
    Reported = [W || W <- seen(Warnings), binary:match(W, <<"does not include">>) =/= nomatch],
    ?assertEqual({min(length(Missing), 1), Why}, {length(Reported), Why}),
    [?assertNotEqual({M, nomatch}, {M, binary:match(hd(Reported), M)}) || M <- Missing],
    stop(App),
    stop(Api).

%%% ------------------------------------------------- what only Cowboy can show

enriches_the_request_and_leaves_the_decision_to_the_handler_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(#{<<"is_vpn">> => true}),
        App = app(#{base_url => base_url(Api), ip_selector => fun(_) -> ?PUBLIC_IP end}),

        {200, Body} = get(App, "/", []),

        ?assertEqual(true, maps:get(<<"attached">>, Body)),
        ?assertEqual(<<"AT">>, maps:get(<<"country">>, Body)),
        ?assertEqual(true, maps:get(<<"is_vpn">>, Body)),
        ?assertEqual(?PUBLIC_IP, maps:get(<<"ip">>, Body)),
        ?assertEqual([?PUBLIC_IP], asked(Api)),
        stop(App),
        stop(Api)
    end}.

a_blocked_request_never_reaches_the_handler_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(located(<<"IR">>)),
        App = app(#{base_url => base_url(Api), ip_selector => fun(_) -> ?PUBLIC_IP end,
                    block_condition => ?COUNTRIES}),

        {Status, Body} = get(App, "/", []),

        ?assertEqual(403, Status),
        ?assertEqual(#{<<"error">> => <<"access denied">>}, Body),
        ?assertEqual(error, maps:find(<<"attached">>, Body)),
        stop(App),
        stop(Api),

        Elsewhere = api(located(<<"AT">>)),
        Passing = app(#{base_url => base_url(Elsewhere), ip_selector => fun(_) -> ?PUBLIC_IP end,
                        block_condition => ?COUNTRIES}),
        {200, Passed} = get(Passing, "/", []),
        ?assertEqual(<<"AT">>, maps:get(<<"country">>, Passed)),
        stop(Passing),
        stop(Elsewhere)
    end}.

%% A condition on `is_bot' reaches the core through the adapter, and the flag is
%% attached under its atom: the corpus's verified crawler, served for its public
%% address, is refused, and an address no bot uses gets through with `is_bot' false.
a_condition_on_is_bot_refuses_a_bot_and_lets_anyone_else_through_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Crawler = lookup_body(<<"paid-bot">>),
        Ip = maps:get(<<"ip">>, Crawler),
        Api = api(Crawler, 200),
        App = app(#{base_url => base_url(Api), ip_selector => fun(_) -> Ip end,
                    block_condition => #{is_bot => true}}),

        ?assertMatch({403, #{<<"error">> := <<"access denied">>}}, get(App, "/", [])),
        ?assertEqual([Ip], asked(Api)),
        stop(App),
        stop(Api),

        Elsewhere = api(#{}),
        Passing = app(#{base_url => base_url(Elsewhere), ip_selector => fun(_) -> ?PUBLIC_IP end,
                        block_condition => #{is_bot => true}}),
        {200, Passed} = get(Passing, "/", []),
        ?assertEqual(true, maps:get(<<"attached">>, Passed)),
        ?assertEqual(false, maps:get(<<"is_bot">>, Passed)),
        ?assertEqual([?PUBLIC_IP], asked(Elsewhere)),
        stop(Passing),
        stop(Elsewhere)
    end}.

on_blocked_replaces_the_refusal_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(located(<<"IR">>)),
        App = app(#{
            base_url => base_url(Api),
            ip_selector => fun(_) -> ?PUBLIC_IP end,
            block_condition => ?COUNTRIES,
            on_blocked => fun(Req, Found) ->
                Country = maps:get(country, maps:get(location, maps:get(result, Found))),
                cowboy_req:reply(451, #{<<"content-type">> => <<"text/plain">>}, Country, Req)
            end
        }),

        ?assertEqual({451, <<"IR">>}, raw(App, "/", [])),
        stop(App),
        stop(Api)
    end}.

skip_leaves_the_request_untouched_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(located(<<"IR">>)),
        App = app(#{
            base_url => base_url(Api),
            ip_selector => fun(_) -> ?PUBLIC_IP end,
            block_condition => ?COUNTRIES,
            skip => fun(Req) -> cowboy_req:path(Req) =:= <<"/healthz">> end
        }),

        {200, Body} = get(App, "/healthz", []),

        ?assertEqual(false, maps:get(<<"attached">>, Body)),
        ?assertEqual([], asked(Api)),
        stop(App),
        stop(Api)
    end}.

a_failing_lookup_lets_the_visitor_through_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(#{<<"error">> => <<"boom">>}, 500),
        App = app(#{base_url => base_url(Api), retries => 0,
                    ip_selector => fun(_) -> ?PUBLIC_IP end,
                    block_condition => ?COUNTRIES}),

        {200, Body} = get(App, "/", []),

        ?assertEqual(<<"server_error">>, maps:get(<<"error">>, Body)),
        stop(App),
        stop(Api)
    end}.

%% The test that matters. Every other assertion here would pass whether or not
%% the selector is right, because a direct connection has nothing to confuse.
a_forged_x_forwarded_for_is_ignored_by_default_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(#{<<"is_vpn">> => true}),
        App = app(#{base_url => base_url(Api)}),

        {200, Body} = get(App, "/", [{"X-Forwarded-For", binary_to_list(?PUBLIC_IP)}]),

        ?assertEqual(<<"127.0.0.1">>, maps:get(<<"ip">>, Body)),
        ?assertEqual(true, maps:get(<<"is_bogon">>, Body)),
        ?assertEqual([], asked(Api)),
        stop(App),

        Trusting = app(#{base_url => base_url(Api),
                         ip_selector => internetdata_selectors:xff(0)}),
        {200, Forwarded} = get(Trusting, "/", [{"X-Forwarded-For", binary_to_list(?PUBLIC_IP)}]),
        ?assertEqual(?PUBLIC_IP, maps:get(<<"ip">>, Forwarded)),
        ?assertEqual([?PUBLIC_IP], asked(Api)),
        stop(Trusting),
        stop(Api)
    end}.

a_header_selector_reads_the_edge_that_writes_it_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(#{<<"is_vpn">> => true}),
        App = app(#{base_url => base_url(Api),
                    ip_selector => internetdata_selectors:header(<<"CF-Connecting-IP">>)}),

        get(App, "/", [{"CF-Connecting-IP", "45.83.91.9"}]),

        ?assertEqual([<<"45.83.91.9">>], asked(Api)),
        stop(App),
        stop(Api)
    end}.

%% Behind a balancer speaking the PROXY protocol, every visitor arrives from the
%% balancer, and the header it writes first on the connection names the visitor.
%% Only a trusted peer's header is read: from anywhere else it is a forgery.
the_proxy_protocol_source_is_read_from_a_trusted_balancer_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(#{<<"is_vpn">> => true}),
        Options = #{base_url => base_url(Api)},
        Trusting = proxied_app(Options#{ip_selector => internetdata_selectors:proxy_protocol([<<"127.0.0.0/8">>])}),
        [begin
             {200, Body} = proxied_get(Trusting, proxy_header(Version, {45, 83, 91, 1})),
             ?assertEqual({Version, ?PUBLIC_IP}, {Version, maps:get(<<"ip">>, Body)}),
             ?assertEqual(true, maps:get(<<"is_vpn">>, Body))
         end || Version <- [1, 2]],
        ?assertEqual([?PUBLIC_IP], asked(Api)),
        %% A balancer's health check carries no source, so the peer answers.
        {200, Local} = proxied_get(Trusting, ranch_proxy_header:header(#{version => 2, command => local})),
        ?assertEqual(<<"127.0.0.1">>, maps:get(<<"ip">>, Local)),
        stop(Trusting),

        Elsewhere = proxied_app(Options#{ip_selector => internetdata_selectors:proxy_protocol([<<"10.9.9.9">>])}),
        {200, Forged} = proxied_get(Elsewhere, proxy_header(1, {45, 83, 91, 2})),
        ?assertEqual(<<"127.0.0.1">>, maps:get(<<"ip">>, Forged)),
        ?assertEqual(true, maps:get(<<"is_bogon">>, Forged)),
        ?assertEqual([?PUBLIC_IP], asked(Api)),
        stop(Elsewhere),

        %% Without the selector the header changes nothing: the default is the peer.
        Default = proxied_app(Options),
        {200, Peer} = proxied_get(Default, proxy_header(2, {45, 83, 91, 3})),
        ?assertEqual(<<"127.0.0.1">>, maps:get(<<"ip">>, Peer)),
        ?assertEqual([?PUBLIC_IP], asked(Api)),
        stop(Default),
        stop(Api)
    end}.

depth_counts_trusted_hops_from_the_right_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(#{<<"is_vpn">> => true}),
        App = app(#{base_url => base_url(Api), ip_selector => internetdata_selectors:xff(1)}),

        get(App, "/", [{"X-Forwarded-For", "45.83.91.1, 70.41.3.18, 150.172.238.178"}]),

        ?assertEqual([<<"150.172.238.178">>], asked(Api)),
        stop(App),
        stop(Api)
    end}.

%% Cowboy's peer is the socket peer with no trusted-proxy setting at all, so on
%% loopback the answer is computed locally and can never block. Local
%% development must not lock you out of your own app.
a_private_client_address_is_answered_locally_and_never_blocks_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Api = api(located(<<"IR">>)),
        App = app(#{base_url => base_url(Api), block_condition => ?COUNTRIES}),

        {Status, Body} = get(App, "/", []),

        ?assertEqual(200, Status),
        ?assertEqual(true, maps:get(<<"is_bogon">>, Body)),
        ?assertEqual([], asked(Api)),
        stop(App),
        stop(Api)
    end}.

a_condition_that_constrains_nothing_is_refused_when_the_core_is_built_test() ->
    ?assertMatch({error, {constrains_nothing, _, _}},
                 internetdata_cowboy:core(#{block_condition => #{is_vpn => false}})).

%% Built as the README builds it. `os:getenv/1' answers `false' for an unset
%% variable, which the core runs with no key, saying so once.
the_readme_setup_builds_with_the_variable_set_or_unset_test() ->
    Previous = os:getenv("INTERNETDATA_API_KEY"),
    try
        os:putenv("INTERNETDATA_API_KEY", "sekrit"),
        {ok, #{core := Keyed}} = internetdata_cowboy:core(#{api_key => os:getenv("INTERNETDATA_API_KEY")}),
        ?assertEqual(<<"sekrit">>, maps:get(api_key, maps:get(client, Keyed))),
        internetdata_middleware:close(Keyed),

        os:unsetenv("INTERNETDATA_API_KEY"),
        Self = self(),
        {ok, #{core := Keyless}} = internetdata_cowboy:core(#{api_key => os:getenv("INTERNETDATA_API_KEY"),
                                                              on_warn => fun(M) -> Self ! {warned, M} end}),
        ?assertEqual(undefined, maps:get(api_key, maps:get(client, Keyless))),
        ?assertMatch([_], warnings()),
        internetdata_middleware:close(Keyless)
    after
        case Previous of
            false -> os:unsetenv("INTERNETDATA_API_KEY");
            Value -> os:putenv("INTERNETDATA_API_KEY", Value)
        end
    end.

warnings() ->
    receive {warned, Message} -> [Message | warnings()] after 0 -> [] end.

%% The README's setup again, from a PUBLIC peer with a forged X-Forwarded-For, the
%% lookup answered by the stub: a core that dropped the key, or read the header by
%% default, would pass the test above. Cowboy's peer is the socket's, which a
%% client on this machine cannot make public, so the request goes to the
%% middleware callback with the peer set where Cowboy sets it.
the_readme_key_reaches_the_api_for_a_public_peer_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        Previous = os:getenv("INTERNETDATA_API_KEY"),
        try
            [begin
                 Api = api(#{}),
                 case Key of
                     false -> os:unsetenv("INTERNETDATA_API_KEY");
                     _ -> os:putenv("INTERNETDATA_API_KEY", Key)
                 end,
                 {ok, Configured} = internetdata_cowboy:core(#{
                     api_key => os:getenv("INTERNETDATA_API_KEY"),
                     base_url => base_url(Api),
                     on_warn => fun(_) -> ok end
                 }),
                 Req = #{peer => {{45, 83, 91, 1}, 40000},
                         headers => #{<<"x-forwarded-for">> => <<"1.1.1.1">>}},
                 {ok, Enriched, _Env} =
                     internetdata_cowboy:execute(Req, #{internetdata => Configured}),
                 Found = internetdata_cowboy:lookup(Enriched),
                 ?assertEqual(?PUBLIC_IP, maps:get(ip, Found)),
                 ?assertEqual(<<"AT">>, maps:get(country, maps:get(location, maps:get(result, Found)))),
                 ?assertEqual([?PUBLIC_IP], asked(Api)),
                 ?assertEqual({Key, [Sent]}, {Key, authorizations(Api)}),
                 internetdata_middleware:close(maps:get(core, Configured)),
                 stop(Api)
             end || {Key, Sent} <- [{"sekrit", <<"Bearer sekrit">>}, {false, undefined}]]
        after
            case Previous of
                false -> os:unsetenv("INTERNETDATA_API_KEY");
                Value -> os:putenv("INTERNETDATA_API_KEY", Value)
            end
        end
    end}.

%% Named in the chain but never configured: every request would otherwise crash
%% on a missing env key, which is the opposite of the fail-open this middleware
%% promises everywhere else.
an_unconfigured_middleware_lets_the_request_through_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1, fun() ->
        App = listen(#{dispatch => dispatch()}),
        {200, Body} = get(App, "/", []),
        ?assertEqual(false, maps:get(<<"attached">>, Body)),
        stop(App)
    end}.

%%% ------------------------------------------------------------------- the app

%% A handler that reports back what the middleware attached.
init(Req, {api, Body, Status, Asked} = State) ->
    Address = iolist_to_binary(lists:join($/, cowboy_req:path_info(Req))),
    Asked ! {asked, Address},
    Asked ! {authorization, cowboy_req:header(<<"authorization">>, Req, undefined)},
    Answer = json:encode(Body#{<<"ip">> => Address}),
    {ok,
        cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>}, Answer, Req),
        State};
init(Req, State) ->
    Found = internetdata_cowboy:lookup(Req),
    Body = json:encode(#{
        <<"attached">> => Found =/= undefined,
        <<"ip">> => at(Found, ip),
        <<"country">> => country(Found),
        <<"is_vpn">> => flag(Found, is_vpn),
        <<"is_bot">> => flag(Found, is_bot),
        <<"is_bogon">> => flag(Found, is_bogon),
        <<"error">> => error_kind(Found)
    }),
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req), State}.

at(undefined, _Key) -> null;
at(Found, Key) -> null_for_undefined(maps:get(Key, Found, undefined)).

flag(undefined, _Key) -> null;
flag(#{result := undefined}, _Key) -> null;
flag(#{result := Result}, Key) -> null_for_undefined(maps:get(Key, Result, undefined)).

country(undefined) -> null;
country(#{result := undefined}) -> null;
country(#{result := #{location := #{country := Country}}}) -> Country.

error_kind(undefined) -> null;
error_kind(#{error := undefined}) -> null;
error_kind(#{error := Error}) -> atom_to_binary(maps:get(kind, Error), utf8).

null_for_undefined(undefined) -> null;
null_for_undefined(Value) -> Value.

app(Options) ->
    {ok, Core} = internetdata_cowboy:core(Options),
    listen(#{dispatch => dispatch(), internetdata => Core}).

dispatch() ->
    cowboy_router:compile([{'_', [{"/[...]", ?MODULE, []}]}]).

listen(Env) ->
    Name = {app, make_ref()},
    {ok, _} = cowboy:start_clear(Name, [{port, 0}], #{
        env => Env,
        middlewares => [cowboy_router, internetdata_cowboy, cowboy_handler]
    }),
    {Name, ranch:get_port(Name)}.

proxied_app(Options) ->
    {ok, Core} = internetdata_cowboy:core(Options),
    Name = {app, make_ref()},
    {ok, _} = cowboy:start_clear(Name, [{port, 0}], #{
        proxy_header => true,
        env => #{dispatch => dispatch(), internetdata => Core},
        middlewares => [cowboy_router, internetdata_cowboy, cowboy_handler]
    }),
    {Name, ranch:get_port(Name)}.

proxy_header(Version, Source) ->
    ranch_proxy_header:header(#{
        version => Version, command => proxy,
        transport_family => ipv4, transport_protocol => stream,
        src_address => Source, src_port => 40000,
        dest_address => {127, 0, 0, 1}, dest_port => 80
    }).

%% httpc cannot write a PROXY header, so the request goes out by hand.
proxied_get({_Name, Port}, Header) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, [Header, <<"GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n">>]),
    Reply = read_all(Socket, <<>>),
    [<<"HTTP/1.1 ", Code:3/binary, _/binary>> = _Head, Body] = binary:split(Reply, <<"\r\n\r\n">>),
    {binary_to_integer(Code), json:decode(Body)}.

read_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} -> read_all(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

%%% ------------------------------------------------------------- the stub API

%% A stand-in API, served by Cowboy on a random port, that answers every lookup
%% from one body and records what it was asked about - so "never touched the
%% network" is asserted rather than assumed. A served answer carries every member
%% the spec requires, so a test's own members go over Unlimited's answer.
api(Members) ->
    api(maps:merge(unlimited(), Members), 200).

api(Body, Status) ->
    Asked = collector(),
    Name = {api, make_ref()},
    Dispatch = cowboy_router:compile([
        {'_', [{"/[...]", ?MODULE, {api, maps:without([<<"ip">>], Body), Status, Asked}}]}
    ]),
    {ok, _} = cowboy:start_clear(Name, [{port, 0}], #{env => #{dispatch => Dispatch}}),
    {Name, ranch:get_port(Name), Asked}.

base_url({_Name, Port, _Asked}) ->
    iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port)]).

asked({_Name, _Port, Collector}) ->
    [A || {asked, A} <- seen(Collector)].

authorizations({_Name, _Port, Collector}) ->
    [A || {authorization, A} <- seen(Collector)].

%% The corpus's Unlimited answer, Unlimited's members with nothing flagged.
unlimited() ->
    lookup_body(<<"unlimited-answer">>).

%% The body of the corpus's lookup case of that name.
lookup_body(Name) ->
    {ok, Raw} = file:read_file(testdata_path()),
    [Body] = [B || #{<<"name">> := N, <<"body">> := B} <- maps:get(<<"lookup">>, json:decode(Raw)), N =:= Name],
    Body.

located(Country) ->
    #{<<"location">> := Location} = unlimited(),
    #{<<"location">> => Location#{<<"country">> => Country}}.

stop({Name, _Port}) -> ok = cowboy:stop_listener(Name);
stop({Name, _Port, _Asked}) -> ok = cowboy:stop_listener(Name).

%%% ------------------------------------------------------------------ helpers

start_apps() ->
    {ok, Started} = application:ensure_all_started([cowboy, inets, ssl]),
    Started.

stop_apps(_Started) ->
    ok.

get(App, Path, Headers) ->
    {Status, Body} = raw(App, Path, Headers),
    {Status, json:decode(Body)}.

raw({_Name, Port}, Path, Headers) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    {ok, {{_, Status, _}, _, Body}} =
        httpc:request(get, {Url, Headers}, [], [{body_format, binary}]),
    {Status, Body}.

%% eunit runs each test in its own process, so a plain collector process is
%% enough and needs no cleanup beyond the test's own lifetime.
collector() ->
    spawn(fun() -> collect([]) end).

collect(Seen) ->
    receive
        {seen, From} ->
            From ! {seen, Seen},
            collect(Seen);
        Message ->
            collect(Seen ++ [Message])
    end.

sink(Pid) ->
    fun(Message) -> Pid ! Message end.

seen(Pid) ->
    Pid ! {seen, self()},
    receive
        {seen, Messages} -> Messages
    after 5000 -> erlang:error(timeout)
    end.

%% What the handler echoes of the answer a corpus case let through.
attached(#{<<"bogon">> := _}, Ip) ->
    #{<<"attached">> => true, <<"ip">> => Ip, <<"is_bogon">> => true, <<"is_bot">> => false,
      <<"error">> => null};
attached(#{<<"body">> := Body}, Ip) ->
    #{<<"attached">> => true, <<"ip">> => Ip, <<"is_bogon">> => maps:get(<<"is_bogon">>, Body, null),
      <<"is_bot">> => maps:get(<<"is_bot">>, Body, null), <<"error">> => null}.

fixture(#{<<"bogon">> := Ip}) ->
    %% Answered locally, so the stub is never asked and the synthesized shape is
    %% what gets pinned rather than a fixture's idea of it.
    {Ip, #{}};
fixture(#{<<"body">> := Body}) ->
    {maps:get(<<"ip">>, Body), Body}.

corpus(Section) ->
    {ok, Raw} = file:read_file(testdata_path()),
    maps:get(Section, maps:get(<<"middleware">>, json:decode(Raw))).

%% rebar3 runs from the project root, but a bare eunit run from anywhere else
%% would not, so fall back to walking up from the built application.
testdata_path() ->
    case filelib:is_regular("testdata/testdata.json") of
        true ->
            "testdata/testdata.json";
        false ->
            filename:join([code:lib_dir(internetdata_cowboy), "..", "..", "..", "..",
                           "testdata", "testdata.json"])
    end.
