# orchd

Keep your services running with one simple file.

You write a short file listing what you want running (a web app, a database, a
worker). orchd starts them, starts them in the right order, restarts them if they
crash, and stops them cleanly when you ask. On a Mac it uses launchd; on Linux it
uses systemd. You do not need to know how either works.

## Install

```sh
cargo build --release
ln -sf target/release/orchd /usr/local/bin/orchd
```

You also need [`orch`](https://github.com/adiled/orch) on your PATH (it reads the file).

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
Apple runtime once, by putting this in a file named `.orchrc` next to your
Orchfile:

```
runtime=apple
```

(Services with `RUN` are plain programs and need no setup. On Linux, containers
use `podman` or `containerd` instead.)

## Use it

```sh
orchd grow      # start everything
orchd survey    # see what is running
orchd logs web  # watch one service
orchd fell      # stop everything and clean up
```

That is the day-to-day. Run `orchd grow` again any time you change the Orchfile.

Set defaults in `.orchrc` (one `KEY=value` per line, like `namespace=myapp`) so
you do not type flags every time. Full list of settings, env vars, and
precedence: [`CONFIG.md`](CONFIG.md).

## Power usage

`orchd grow` is really three small steps. Run them yourself when you want to slip
your own logic in the middle:

```sh
orch parse Orchfile \
  | orchd sow --runtime apple \           # services -> run commands
  | orchd plant --platform launchd \      # -> native service files
  | orchd tend                            # -> running
```

Every step is plain JSON in, JSON out, so you can pipe anything between them:

```sh
... | orchd sow | jq 'del(.cuttings[0])' | orchd plant | ...
```

orchd has no opinion about how you compose; that part is yours. Full reference:
[`ORCHARD.md`](ORCHARD.md).

On a Mac, the Apple runtime can run Linux containers with no Docker and no
background daemon at all, using only macOS itself. Add `ORCHD_APPLE_MODE=osx`.
How it works: [`ORCHD_OSX.md`](ORCHD_OSX.md).

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).
