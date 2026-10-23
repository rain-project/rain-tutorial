use code::{Directory, Secrets};
use drop::crypto::{hash::Key, sign::KeyPair};
use rain::Membership;
use std::{collections::HashMap, fs, iter, path::PathBuf};

const NODES_ROOT: &str = "/work/nodes";
const SERVER_COUNT: usize = 6;

fn main() {
    // Generate server hostnames

    let servers = (0..SERVER_COUNT)
        .map(|i| format!("server{i}"))
        .collect::<Vec<_>>();

    // Generate one `KeyPair` per server

    let mut key_pairs = iter::repeat_with(KeyPair::random)
        .take(SERVER_COUNT)
        .collect::<Vec<_>>();

    // Generate shared `Membership` from `key_pairs`' `Public`s

    let membership = Membership::new(key_pairs.iter().map(|key_pair| key_pair.public.clone()));

    // Assemble host table

    let hosts = membership
        .identities()
        .iter()
        .zip(servers.iter().cloned())
        .map(|(identity, host)| (*identity, host))
        .collect::<HashMap<_, _>>();

    let directory = Directory { membership, hosts };

    // Persist `directory` to `shared` folder

    let shared_path = PathBuf::from(NODES_ROOT).join("shared");
    fs::create_dir_all(&shared_path).unwrap();

    fs::write(
        shared_path.join("directory"),
        postcard::to_allocvec(&directory).unwrap(),
    )
    .unwrap();

    // Generate and persist each server's `Secrets`

    for &identity in directory.membership.identities().iter() {
        let hostname = directory.hosts.get(&identity).unwrap().clone();

        let index = key_pairs
            .iter()
            .position(|key_pair| key_pair.public.identity() == identity)
            .unwrap();

        let key_pair = key_pairs.swap_remove(index);
        let symmetric_key = Key::random();

        let secrets = Secrets {
            key_pair,
            symmetric_key,
        };

        let server_path = PathBuf::from(NODES_ROOT).join(&hostname);
        fs::create_dir_all(&server_path).unwrap();

        fs::write(
            server_path.join("secrets"),
            postcard::to_allocvec(&secrets).unwrap(),
        )
        .unwrap();

        println!("  ✓ {hostname}: /work/nodes/{hostname}/secrets");
    }

    println!("init: initialized {SERVER_COUNT} servers");
}
