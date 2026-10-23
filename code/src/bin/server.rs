use code::{Directory, Secrets};
use drop::net::{connectors::Tcp as TcpConnector, listeners::Tcp as TcpListener, Responder};
use rain::{
    Application, ApplicationError, Request, Server, ServerBuilder, ServerRefund, ServerSettings,
};
use std::{
    fs,
    io::{Read, Write},
    path::PathBuf,
};
use tokio::signal::unix::{signal, SignalKind};

// `Summer` application

struct Summer {
    value: u64,
}

impl Application for Summer {
    type Configuration = ();

    fn setup(_: ()) -> Self {
        Summer { value: 0 }
    }

    fn load(_: ()) -> Self {
        let mut buffer = [0u8; 8];

        fs::File::open(SUMMER_STATE_PATH)
            .unwrap()
            .read_exact(&mut buffer)
            .unwrap();

        Summer {
            value: u64::from_be_bytes(buffer),
        }
    }

    fn serve(&mut self, requests: &mut [Request]) {
        for request in requests {
            if request.len() != 8 {
                continue;
            }

            let addend = u64::from_be_bytes(request.request().try_into().unwrap());
            self.value = self.value.wrapping_add(addend);

            request.respond(self.value.to_be_bytes().to_vec());
        }
    }

    fn shutdown(self) {
        let mut file = fs::File::create(SUMMER_STATE_PATH).unwrap();
        file.write_all(&self.value.to_be_bytes()).unwrap();
        file.sync_all().unwrap();
    }

    fn serialize_into<W: Write>(&self, writer: &mut W) -> Result<(), ApplicationError> {
        writer.write_all(&self.value.to_be_bytes())?; 
        Ok(())
    }

    fn deserialize_from<R: Read>(reader: &mut R, _: ()) -> Result<Self, ApplicationError> {
        let mut buffer = [0u8; 8];
        reader.read_exact(&mut buffer)?;

        Ok(Summer {
            value: u64::from_be_bytes(buffer),
        })
    }
}

// --- Server main

const SECRETS_PATH: &str = "/state/secrets";
const DIRECTORY_PATH: &str = "/shared/directory";
const RAIN_STATE_PATH: &str = "/state/rain";
const SUMMER_STATE_PATH: &str = "/state/summer";
const SERVER_PORT: u16 = 1234;
const SIGNUP_PORT: u16 = 1235;

#[tokio::main]
async fn main() {
    // Parse args (only `--force-recovery` is meaningful)

    let force_recovery = std::env::args().any(|arg| arg == "--force-recovery");

    // Load `Secrets` and `Directory`

    let Secrets {
        key_pair,
        symmetric_key,
    } = postcard::from_bytes::<Secrets>(&fs::read(SECRETS_PATH).unwrap()).unwrap();

    let directory = postcard::from_bytes::<Directory>(&fs::read(DIRECTORY_PATH).unwrap()).unwrap();

    // Setup server `Connector` and `Listener`

    let server_connector = TcpConnector::new(key_pair.clone(), Default::default());

    for (identity, host) in directory.hosts {
        server_connector.set_host(identity, (host.as_str(), SERVER_PORT));
    }

    let server_listener = TcpListener::new(
        key_pair.clone(),
        ("0.0.0.0", SERVER_PORT),
        Default::default(),
    )
    .await
    .unwrap();

    // Setup signup `Listener`

    let mut signup_listener = TcpListener::new(
        key_pair.clone(),
        ("0.0.0.0", SIGNUP_PORT),
        Default::default(),
    )
    .await
    .unwrap();

    // Compute paths and settings

    let server_settings = ServerSettings::default();

    // Boot `Server`: setup, load, or recover

    let provision = if !PathBuf::from(RAIN_STATE_PATH).exists() && !force_recovery {
        // Fresh setup

        fs::create_dir_all(RAIN_STATE_PATH).unwrap();

        let builder = ServerBuilder::<Summer, _, _, _> {
            key_pair,
            symmetric_key,
            membership: directory.membership,
            root: PathBuf::from(RAIN_STATE_PATH),
            connector: server_connector,
            listener: server_listener,
            server_settings,
            application_configuration: (),
        };

        builder.setup().await.unwrap()
    } else {
        // Attempt to load

        let load_result = if !force_recovery {
            Server::load(
                PathBuf::from(RAIN_STATE_PATH),
                server_connector,
                server_listener,
                (),
            )
            .await
            .map_err(|(refund, _)| refund)
        } else {
            Err(ServerRefund {
                connector: server_connector,
                listener: server_listener,
            })
        };

        match load_result {
            Ok(provision) => provision,

            Err(refund) => {
                // Wipe local state and recover from peers

                let _ = fs::remove_dir_all(RAIN_STATE_PATH);
                let _ = fs::remove_file(SUMMER_STATE_PATH);

                fs::create_dir_all(RAIN_STATE_PATH).unwrap();

                let builder = ServerBuilder::<Summer, _, _, _> {
                    key_pair,
                    symmetric_key,
                    membership: directory.membership,
                    root: PathBuf::from(RAIN_STATE_PATH),
                    connector: refund.connector,
                    listener: refund.listener,
                    server_settings,
                    application_configuration: (),
                };

                builder.recover().await.unwrap()
            }
        }
    };

    // Main loop

    eprintln!("server up on {SERVER_PORT} (server), {SIGNUP_PORT} (signup)");

    let mut term = signal(SignalKind::terminate()).unwrap();
    let mut int = signal(SignalKind::interrupt()).unwrap();
    let mut hup = signal(SignalKind::hangup()).unwrap();

    loop {
        tokio::select! {
            result = signup_listener.respond() => {
                let (identity, mut thread) = result.unwrap();
                let index = provision.signup(identity).await;
                let _ = thread.send_authenticated(&index).await;
            }

            _ = term.recv() => break,
            _ = int.recv() => break,
            _ = hup.recv() => continue,
        }
    }

    // Shutdown — extract `Server` from `ServerProvision` to consume it

    eprintln!("received signal, shutting down");
    Server::from(provision).shutdown().await;
    eprintln!("shutdown complete");
}
