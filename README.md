# [<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" height="28"/>](https://internetdata.io/) InternetData Cowboy Middleware

[![Hex.pm](https://img.shields.io/hexpm/v/internetdata_cowboy.svg)](https://hex.pm/packages/internetdata_cowboy)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/internetdata_cowboy)
[![license](https://img.shields.io/github/license/internetdata/sdk-erlang-cowboy.svg)](LICENSE)

The official [Cowboy](https://github.com/ninenines/cowboy) middleware for the [InternetData](https://internetdata.io) API.

It looks up the visitor behind each request, where they are, which network they come from and whether it's a VPN, a proxy, Tor or a hosting server, and puts the answer on the request. Blocking is opt-in.

Elixir's `Plug.Cowboy` runs the same middleware chain, so this works there too through `protocol_options`.

## Getting Started

```erlang
{deps, [{internetdata_cowboy, "~> 1.1"}]}.
```

In a release, also name both in your `.app.src`, or the release boots without them and the first request fails with `undef`:

```erlang
{applications, [kernel, stdlib, cowboy, internetdata_cowboy]}
```

Requires OTP 27 or newer, and Cowboy 2.21 or newer.

Without an API key a lookup is on Unlimited, the free plan: the country, the network and the company behind the address, Tor, relay, anycast, carrier and satellite space, bots and the service flags, with no daily or monthly cap. Every lookup your app makes comes from your server's one address, though, so a busy site will see bursts refused. A paid plan answers every field, VPN, the proxy flags, hosting, CDN and the city among them; create a key in the [console](https://app.internetdata.io). A free account tries every field.

Build the core once, at startup, and name this module in the chain:

```erlang
{ok, Core} = internetdata_cowboy:core(#{api_key => os:getenv("INTERNETDATA_API_KEY")}),
Dispatch = cowboy_router:compile([{'_', [{"/", my_handler, []}]}]),
{ok, _} = cowboy:start_clear(http, [{port, 8080}], #{
    env => #{dispatch => Dispatch, internetdata => Core},
    middlewares => [cowboy_router, internetdata_cowboy, cowboy_handler]
}).
```

**After `cowboy_router`**, so a request no route matches gets its 404 from the router without costing a lookup, and a `skip` can read the `bindings` and `path_info` the router set; **before `cowboy_handler`**, so a blocked request never reaches one.

The core owns the HTTP client and the answer cache, so build it once. One per request would mean neither ever helps. With the variable unset, `os:getenv/1` answers `false` and the core runs with no key, saying so once.

Your handler reads what it found:

```erlang
init(Req, State) ->
    Body = case internetdata_cowboy:lookup(Req) of
        #{result := #{location := #{country_name := Country}}} ->
            <<"Hello, visitor from ", Country/binary>>;
        _ ->
            <<"Hello">>
    end,
    {ok, cowboy_req:reply(200, #{}, Body, Req), State}.
```

By default nothing is blocked. Every request carries a lookup and your own handlers decide what it means: a currency to show, a sign-up to review, a page to keep from some countries.

## Blocking

Set a `block_condition` and a matching request is answered with `403` and never reaches your handlers.

```erlang
internetdata_cowboy:core(#{
    api_key => os:getenv("INTERNETDATA_API_KEY"),
    block_condition => #{location => #{country => [<<"CU">>, <<"IR">>, <<"KP">>]}}
}).
```

A condition is written in the shape of a result, keyed by the same names the API uses, and only the members you name are considered, so it can refuse on anything in the answer. The country works on every plan, and so do the first three of these:

```erlang
%% the network's type
#{asn => #{type => <<"hosting">>}}

%% anycast and satellite space: a list is OR
[#{is_anycast => true}, #{is_satellite => true}]

%% automated clients: crawlers, uptime monitors, scanners
#{is_bot => true}

%% traffic from servers, not people
[#{is_hosting => true}, #{is_cdn => true}]

%% anonymity
[#{is_vpn => true}, #{is_tor => true}, #{is_resproxy => true}]

%% one provider
#{is_vpn => true, vpn => #{provider => <<"nordvpn">>}}

%% a numeric threshold
#{resproxy => #{hits => #{gte => 5}}}
```

Values are matched by equality, strings without regard to case. A list means any-of. Against a member the answer holds as a list (`web`'s rows, `pubproxy.protocols`), a value matches when any one element does, and a map must match one element whole: `#{web => #{port => 443}}`. A map of `gte`/`gt`/`lte`/`lt` bounds a number and combines into a range; every bound you give must hold. Members set to `false`, `null` or `undefined` are ignored, so a condition states the signals you act on; one that constrains nothing would match every request, and is refused when the core is built rather than silently blocking all your traffic.

Atom and binary keys both work, so a condition can come straight out of `json:decode/1` on your app's config file:

```erlang
{ok, Raw} = file:read_file("policy.json"),
internetdata_cowboy:core(#{api_key => os:getenv("INTERNETDATA_API_KEY"), block_condition => json:decode(Raw)}).
```

**Write strings as binaries.** An Erlang string is a list of codepoints, so `"nordvpn"` and an any-of of those numbers are the same term. A bare string is accepted anyway, but binaries have no such ambiguity and are what `json:decode/1` produces.

Replace the refusal with `on_blocked`, which must reply:

```erlang
on_blocked => fun(Req, _Found) ->
    cowboy_req:reply(451, #{}, <<"Not available in your country">>, Req)
end
```

## Letting verified crawlers through

Set `allow_bots => true` and the middleware sends each request's own `User-Agent` with its lookup, and a request whose answer says its agent is `verified` (the agent's operator, such as Google for Googlebot, vouches for the address) is never refused, whatever your `block_condition` matches. The answer is still attached, with its `user_agent` verdict:

```erlang
internetdata_cowboy:core(#{api_key => Key, allow_bots => true,
                           block_condition => #{is_hosting => true}}).
```

```erlang
case internetdata_cowboy:lookup(Req) of
    #{result := #{user_agent := #{agent := Agent, verdict := <<"verified">>}}} -> {crawler, Agent};
    _ -> visitor
end
```

A request with no `User-Agent`, or an empty one, sends none. A condition can name the verdict, such as `#{user_agent => #{verdict => <<"spoofed">>}}` to refuse a crawler that is not what it claims; it can match only with `allow_bots` on. The verdict needs every field (a paid plan, or the trial): when an agent was sent and the answer carries no `user_agent`, nothing is let through and the middleware warns once, as `on_missing_field` says. Off by default, so the cache holds one answer per address rather than one per agent.

## Where the client address comes from

This is the setting that decides whether any of the above works, and it is the one thing only you can get right.

By default the middleware uses `cowboy_req:peer/1`. **Cowboy has no trusted-proxy setting**, so that is the socket peer and nothing else. If your app sits behind nginx, a load balancer, or a CDN, every visitor arrives wearing your proxy's address, and that is the address that gets looked up: every visitor gets your proxy's country and network, and if it is a hosting address, a hosting rule blocks everyone. nginx on the same machine is `127.0.0.1` and a load balancer usually has a private address, which the middleware answers locally without a lookup, as an address with no country, and logs a warning.

For an edge that writes the address into its own header, name the header:

```erlang
ip_selector => internetdata_selectors:header(<<"CF-Connecting-IP">>)   % or True-Client-IP
```

`internetdata_selectors:xff(0)` reads the left-most `X-Forwarded-For` entry. Be aware that the left-most entry is whatever the caller sent, because proxies append to that header, so it's only trustworthy when an edge you control overwrites it. If you know how many proxies sit in front, count from the right instead: `xff(1)` is the address your nearest proxy saw.

Behind a balancer that speaks the PROXY protocol (nginx's stream module with `proxy_protocol on`, HAProxy's `send-proxy`), start the listener with `proxy_header => true` and read the source address the header carries. Cowboy reads any connection's header that way, so the selector believes it only from the balancers you list, as addresses or CIDR blocks, and answers the socket peer for anyone else:

```erlang
{ok, _} = cowboy:start_clear(http, [{port, 8080}], #{
    proxy_header => true,
    env => #{dispatch => Dispatch, internetdata => Core},
    middlewares => [cowboy_router, internetdata_cowboy, cowboy_handler]
}),
```

and build the core with the selector:

```erlang
ip_selector => internetdata_selectors:proxy_protocol([<<"10.0.0.0/8">>])
```

A balancer's own health check sends a header with no source, and is checked as the balancer. Cowboy's own guide says to enable `proxy_header` only on a listener that nothing but your balancers can reach.

Anything else, pass your own fun. It receives a view of the request and returns an address:

```erlang
ip_selector => fun(View) -> (maps:get(header, View))(<<"x-real-ip">>) end
```

If the address resolves to a private one, the middleware says so once through `on_warn`, which defaults to `logger:warning/1`. That is expected on localhost and is the signal to fix your configuration anywhere else.

## When a lookup fails

The request is let through, and the reason is on the lookup's `error` key. Our outage should not become yours, so a network failure, a rate limit or a rejected key all fail open.

```erlang
case internetdata_cowboy:lookup(Req) of
    #{error := #{kind := Kind}} ->
        logger:warning("internetdata unavailable: ~p", [Kind]);
    _ ->
        ok
end
```

Set `fail_closed => true` to block instead. Private addresses are answered locally and never fail, so this will not lock you out in development.

## Cost and latency

Answers are cached per core for an hour, so a returning visitor costs nothing, and private addresses never leave the process. A cache miss is one request to our API, bounded at 2500 ms by default and not retried: on a request path, failing open quickly beats holding a visitor while we try again. Both are adjustable, and so is the cache, through a client you build yourself and pass as `client`.

Skip what you do not care about:

```erlang
skip => fun(Req) -> cowboy_req:path(Req) =:= <<"/healthz">> end
```

If you already hold an `internetdata` client, pass it as `client` and the middleware will share it rather than building a second cache.

Beyond a few million distinct visitors a day, stop calling the API per request: look addresses up locally in [our databases](https://internetdata.io/databases) instead.

## Absent is not false

Unlimited, with a key or without one, leaves out `is_vpn`, `is_hosting`, `is_cdn` and the four proxy flags, the detail behind them, `bot` (it answers `is_bot`), and the paid members inside `location`, `asn`, `company` and `abuse`, such as `city`. A key your plan does not include is ABSENT from the result map, which means "not in your plan" rather than "checked, and no".

```erlang
maps:get(is_vpn, Result, false)        % when you only want the flag
maps:get(is_vpn, Result, undefined)    % when the difference matters
```

A `block_condition` naming a member your plan does not serve, `location.city` on Unlimited included, can never match, so the middleware warns once instead of failing silently. Set `on_missing_field => error` to make it an error, which this middleware answers with a `500`.

## Other Libraries

There are official InternetData client libraries available for many languages including PHP, Python, Go, Java, and Ruby. See our GitHub at https://github.com/internetdata for more.

## About InternetData

Geolocation, anonymity, ownership, network, service and domain data for any IP address, AS or domain, by API or as databases you download.

[<picture><source media="(prefers-color-scheme: dark)" srcset="https://s3.internetdata.io/internetdata-public/brand/logo-dark.svg"><img src="https://s3.internetdata.io/internetdata-public/brand/logo.svg" alt="InternetData" height="40"/></picture>](https://internetdata.io/)

## License

This project is licensed under the [MIT License](LICENSE).
