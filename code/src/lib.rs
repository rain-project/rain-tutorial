use drop::crypto::{hash::Key, sign::KeyPair, Identity};
use rain::Membership;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Cluster-wide directory: the membership set plus a map from each
/// identity to the hostname docker compose will resolve to that node.
///
/// Written once by `init`; read by every server and every client.
/// Lives at `/shared/directory` inside sim containers (host: `nodes/shared/directory`).
#[derive(Serialize, Deserialize)]
pub struct Directory {
    pub membership: Membership,
    pub hosts: HashMap<Identity, String>,
}

/// Per-server secrets: signing keypair and a symmetric key.
///
/// Written once by `init` into that server's state folder; read by that server only.
/// Lives at `/state/secrets` inside the server's container (host: `nodes/serverN/secrets`).
#[derive(Serialize, Deserialize)]
pub struct Secrets {
    pub key_pair: KeyPair,
    pub symmetric_key: Key,
}
