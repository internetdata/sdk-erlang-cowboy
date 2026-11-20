# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff.

## 1.0.4 - 2026-11-20

### Fixes

- Require internetdata 1.17.3: its docs no longer give the trial a count ([`02935ea`](https://github.com/internetdata/sdk-erlang-cowboy/commit/02935ea4d833471674714a02bce07a18850d67ad))

## 1.0.3 - 2026-11-19

### Fixes

- Require internetdata 1.17.2: a reduced answer is cached a minute at most ([`aceffd7`](https://github.com/internetdata/sdk-erlang-cowboy/commit/aceffd7dd09dd825bbccbf06b640a780d0a55466))

## 1.0.2 - 2026-11-19

### Fixes

- Require Cowboy 2.18: older releases carry three security advisories ([`67f72ae`](https://github.com/internetdata/sdk-erlang-cowboy/commit/67f72aec6119c400a881c14cb0c8bef3b3c622e2))
- Require internetdata 1.17.1 and Cowboy 2.21 ([`2356aa1`](https://github.com/internetdata/sdk-erlang-cowboy/commit/2356aa1160f40543ccda4ac822bc2449a1471eb1))

## 1.0.1 - 2026-11-14

### Fixes

- Require internetdata 1.14.1: a 403 can mean the key lacks the ip.lookup scope ([`ccfa7cc`](https://github.com/internetdata/sdk-erlang-cowboy/commit/ccfa7cc4acc52606306afaee44fefc40a6c45a74))

## 1.0.0 - 2026-11-14

### Features

- Attach the visitor's InternetData record to every request, read with `internetdata_cowboy:lookup/1`: the location, the network and the company behind the address, and the anonymity and hosting flags your plan serves ([`30bcd39`](https://github.com/internetdata/sdk-erlang-cowboy/commit/30bcd398a527d35448c0632446e6dfd40d1a8435))
- Refuse a request with a `block_condition` written in the shape of a result or decoded from JSON, by country, network type, anonymity or any other member, with 403 or an `on_blocked` of your own ([`30bcd39`](https://github.com/internetdata/sdk-erlang-cowboy/commit/30bcd398a527d35448c0632446e6dfd40d1a8435))
- Choose where the client address comes from: the socket peer by default, `internetdata_selectors:xff/1`, `header/1` for a header your edge writes, `proxy_protocol/1` for a trusted balancer's PROXY header, or a fun of your own ([`30bcd39`](https://github.com/internetdata/sdk-erlang-cowboy/commit/30bcd398a527d35448c0632446e6dfd40d1a8435))
- Fail open on any lookup failure unless `fail_closed` is set, with a 2500 ms bound, no retry and a cache per core by default ([`30bcd39`](https://github.com/internetdata/sdk-erlang-cowboy/commit/30bcd398a527d35448c0632446e6dfd40d1a8435))
