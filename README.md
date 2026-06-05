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

## Use it

```sh
orchd grow      # start everything
orchd survey    # see what is running
orchd logs web  # watch one service
orchd fell      # stop everything and clean up
```

That is the day-to-day. Run `orchd grow` again any time you change the Orchfile.

## Going further

- **Settings:** drop an `.orchrc` file (`KEY=value` per line) to set defaults like
  `namespace=myapp` or `runtime=apple`, so you do not type flags every time.
- **Build your own tooling:** `grow` is just three smaller steps you can pipe and
  reshape: `orchd sow | orchd plant | orchd tend`. See [`ORCHARD.md`](ORCHARD.md).

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).
