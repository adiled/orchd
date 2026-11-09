# orchd

Keep your services running with one simple file.

You write a short file listing what you want running (a web app, a database, a
worker). orchd starts them, starts them in the right order, restarts them if they
crash, and stops them cleanly when you ask. On a Mac it uses launchd; on Linux it
uses systemd. You do not need to know how either works.

## Install

From a [release](https://github.com/adiled/orchd/releases): unpack
`orchd-<target>.tar.gz` and put its `bin/` on your `PATH`. It carries orchd, its
rootstocks and `orch`, the parser orchd reads Orchfiles with; orchd finds them
beside it, so keep them together.

From source, with Zig 0.17.1, [`just`](https://github.com/casey/just) and
[`orch`](https://github.com/adiled/orch) on your `PATH`:

```sh
just install
```

That installs into `/usr/local/bin` (set `PREFIX` for elsewhere).

## Write an Orchfile

Put a file named `Orchfile` next to your project. Each `SERVICE` is one thing to
run. Here is a database and a web app that needs it:

```
SERVICE database
FROM postgres:16
ENV POSTGRES_PASSWORD=secret
HEALTHCHECK pg_isready -h localhost

SERVICE web
RUN myapp --port 8000
REQUIRES database
HEALTHCHECK http://localhost:8000
RESTART on-failure
```

`REQUIRES database` means web waits until the database is actually ready. That is
the whole idea: say what you want, orchd handles the rest. (The full list of
options lives in the [Orch spec](https://github.com/adiled/orch).)

A service with `FROM` is a Linux container. On a Mac, tell orchd to use the
Apple rootstock once, by putting this in a file named `.orchrc` next to your
Orchfile:

```
rootstock=apple
```

(Services with `RUN` are plain programs and need no setup. On Linux, containers
use `podman` or `containerd` instead.)

## Use it

```sh
orchd grow               # start everything
orchd grow web --reload  # run web's RELOAD instead of restarting it
orchd survey             # see what is running
orchd logs web           # watch one service
orchd fell web           # stop one service and clean it up
orchd fell               # stop everything and clean up
```

That is the day-to-day. Run `orchd grow` again any time you change the Orchfile.

Set defaults in `.orchrc` (one `KEY=value` per line, like `grove=myapp`) so
you do not type flags every time. Full list of settings, env vars, and
precedence: [`CONFIG.md`](CONFIG.md).

## Power usage

`orchd grow` is really three small steps. Run them yourself when you want to slip
your own logic in the middle:

```sh
orch parse Orchfile \
  | orchd sow --rootstock apple \        # services -> run commands
  | orchd plant --platform launchd \     # -> native service files
  | orchd tend                           # -> running
```

Every step is plain JSON in, JSON out, so you can pipe anything between them:

```sh
... | orchd sow | jq 'del(.cuttings[0])' | orchd plant | ...
```

orchd has no opinion about how you compose; that part is yours. Full reference:
[`ORCHARD.md`](ORCHARD.md).

A rootstock is what runs each service, and each is its own small program
beside orchd: `bare` (a plain process), and on a Mac `apple` (Apple's
`container`) and `applz`. Any `orchd-rootstock-<name>` beside orchd or on your
`PATH` is one more. Bring your own: the contract is a few verbs and some JSON, in
[`ORCHARD.md`](ORCHARD.md#bring-your-own-rootstock).

On a Mac, [applz](https://github.com/adiled/applz) runs Linux containers with no
Docker and no background daemon at all, using only macOS itself. Install it and
grow with `--rootstock applz`; orchd ships the `orchd-rootstock-applz` that
speaks to it.

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).
