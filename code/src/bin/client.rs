use code::Directory;
use drop::{
    crypto::sign::KeyPair,
    net::{connectors::Tcp as TcpConnector, Initiator},
};
use rain::{Client, ClientBuilder, Process};
use serde::{Deserialize, Serialize};
use std::{fs, io::Write, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    signal::unix::{signal, SignalKind},
    time,
};

// `ClientState` — persisted keypair + assigned index

#[derive(Serialize, Deserialize)]
struct ClientState {
    key_pair: KeyPair,
    index: usize,
}

// --- Client main

const DIRECTORY_PATH: &str = "/shared/directory";
const STATE_PATH: &str = "/state/client";
const SERVER_PORT: u16 = 1234;
const SIGNUP_PORT: u16 = 1235;

#[tokio::main]
async fn main() {
    // Parse args — `--auto [SEC]` for auto mode (default 1s), else interactive

    let args = std::env::args().skip(1).collect::<Vec<_>>();

    let (auto, interval_secs) = match args.first().map(|s| s.as_str()) {
        Some("--auto") => (
            true,
            args.get(1).and_then(|s| s.parse::<u64>().ok()).unwrap_or(1),
        ),
        _ => (false, 0),
    };

    // Load `Directory`

    let directory = postcard::from_bytes::<Directory>(&fs::read(DIRECTORY_PATH).unwrap()).unwrap();

    // Load or generate `ClientState` — signing up on first launch, reusing on subsequent

    let ClientState { key_pair, index } = if fs::exists(STATE_PATH).unwrap() {
        postcard::from_bytes(&fs::read(STATE_PATH).unwrap()).unwrap()
    } else {
        eprintln!("no state found — generating keypair and signing up");

        let key_pair = KeyPair::random();

        // Sign up: connect to a random server's signup port; receive assigned index

        let signup_connector = TcpConnector::new(key_pair.clone(), Default::default());

        for (&identity, host) in directory.hosts.iter() {
            signup_connector.set_host(identity, (host.as_str(), SIGNUP_PORT));
        }

        let server = directory.membership.identities()
            [rand::random_range(0..directory.membership.count())];

        let mut thread = signup_connector.initiate(server).await.unwrap();
        let index = thread.receive_authenticated::<usize>().await.unwrap();

        // Persist

        let state = ClientState { key_pair, index };
        let mut file = fs::File::create(STATE_PATH).unwrap();
        file.write_all(&postcard::to_allocvec(&state).unwrap()).unwrap();
        file.sync_all().unwrap();

        eprintln!("signed up as client {index}");

        state
    };

    // Build `Client`

    let server_connector = TcpConnector::new(key_pair.clone(), Default::default());

    for (&identity, host) in directory.hosts.iter() {
        server_connector.set_host(identity, (host.as_str(), SERVER_PORT));
    }

    let builder = ClientBuilder {
        process: Process::Client(index),
        key_pair,
        membership: directory.membership,
        connector: server_connector,
        settings: Default::default(),
    };

    let client = Client::from(builder.new().await);

    eprintln!(
        "client {index} ready ({})",
        if auto {
            format!("auto, every {interval_secs}s")
        } else {
            String::from("interactive — enter a u64 per line")
        }
    );

    // Run

    let mut term = signal(SignalKind::terminate()).unwrap();
    let mut int = signal(SignalKind::interrupt()).unwrap();

    if auto {
        let mut ticker = time::interval(Duration::from_secs(interval_secs));

        loop {
            tokio::select! {
                _ = ticker.tick() => {
                    let addend: u64 = 1;
                    let response = client.broadcast(&addend.to_be_bytes()).await;
                    let sum = u64::from_be_bytes(response.try_into().unwrap());
                    println!("+{addend} → sum = {sum}");
                }
                _ = term.recv() => break,
                _ = int.recv() => break,
            }
        }
    } else {
        let mut reader = BufReader::new(tokio::io::stdin());
        let mut line = String::new();

        loop {
            line.clear();

            tokio::select! {
                read = reader.read_line(&mut line) => {
                    if read.unwrap() == 0 { break; }

                    let Ok(addend) = line.trim().parse::<u64>() else {
                        eprintln!("not a u64: {}", line.trim());
                        continue;
                    };

                    let response = client.broadcast(&addend.to_be_bytes()).await;
                    let sum = u64::from_be_bytes(response.try_into().unwrap());
                    println!("+{addend} → sum = {sum}");
                }
                _ = term.recv() => break,
                _ = int.recv() => break,
            }
        }
    }

    eprintln!("client shutting down");
}
