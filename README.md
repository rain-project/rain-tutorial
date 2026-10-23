# rain tutorial

A six-server [rain](https://github.com/rain-project/rain) cluster running a toy application: clients send a `u64`, servers reply with the running sum.

## Setup

You need Docker (with Compose) and a GitHub token for the private `rain` and `drop` crates. Ask Matteo for the token.

```bash
cp .env.example .env   # then paste the token into .env
```

## Run

```bash
./rain.sh up                 # build, initialize, start all 6 servers
./rain.sh client -t 0        # interactive client: type a number per line
./rain.sh client 1 -- --auto # background client adding 1 every second
./rain.sh status
./rain.sh down               # stop servers and clients
```

Single servers can be stopped and restarted with `./rain.sh down N` / `./rain.sh up N`. `./rain.sh reset` wipes the cluster state. `./rain.sh help` lists everything else.

## Code

Everything lives in `code/src`:

- `bin/init.rs` generates keys and the shared membership
- `bin/server.rs` implements the application and runs a server
- `bin/client.rs` signs up and sends requests

## Editing

Open the folder in VS Code and accept "Reopen in Container" for a ready-made Rust environment, or use `./rain.sh dev` for a shell inside it. The first build fetches dependencies and takes a few minutes.
