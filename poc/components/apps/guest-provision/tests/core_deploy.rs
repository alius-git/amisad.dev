// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 426433db-4518-43aa-8cd3-87e0c196c052

#![cfg(target_os = "linux")]

use std::{env, fs, os::unix::fs::PermissionsExt, path::PathBuf, process::Command, sync::Mutex};

static FIXTURE_TOOLS: Mutex<()> = Mutex::new(());

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn rotates_secrets_before_importing_images_and_exposes_ports_after_rollout() {
    let _fixture = FIXTURE_TOOLS.lock().unwrap();
    let directory = Command::new("mktemp")
        .args(["-dt", "amisad-core-deploy.XXXXXXXX"])
        .output()
        .unwrap();
    assert!(directory.status.success());
    let scratch = Scratch(PathBuf::from(
        String::from_utf8(directory.stdout).unwrap().trim(),
    ));
    let path = &scratch.0;
    let tools = path.join("bin");
    fs::create_dir(&tools).unwrap();
    fs::create_dir_all(path.join("target/release")).unwrap();
    let services = [
        "seller-svc",
        "resource-svc",
        "ads-svc",
        "insights-svc",
        "platform-svc",
        "audit-svc",
        "connect-svc",
        "fabric-coordinator",
        "identity-mock",
        "ledger-svc",
    ];
    for service in services {
        fs::write(
            path.join("target/release").join(service),
            "fixture executable",
        )
        .unwrap();
    }
    let fake = r#"#!/bin/bash
name=${0##*/}
case "$name $*" in
    'getent '*) exit 1 ;;
    'openssl rand -hex 24') printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
    'openssl rand -hex 32') printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
    'sudo -u postgres pg_isready -q') echo pg-ready >> "$TRACE" ;;
    'sudo -u postgres psql '*) IFS= read -rd '' value; [[ "$value" == *"ALTER ROLE amisad LOGIN PASSWORD 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'"* ]] || exit 19; echo sql >> "$TRACE" ;;
    'sudo ctr -n k8s.io images import -') IFS= read -r images; [[ "$images" == 'ten image archive' ]] || exit 19; echo import >> "$TRACE" ;;
    'kubectl --request-timeout=2s get --raw=/readyz') echo api-ready >> "$TRACE" ;;
    'kubectl get namespace amisad') echo namespace >> "$TRACE" ;;
    'kubectl -n amisad delete secret '*) printf 'delete %s\n' "$5" >> "$TRACE" ;;
    'kubectl create -f -')
        IFS= read -rd '' value
        if [[ "$value" == *'"name":"amisad-database"'* && "$value" == *'"password":"YWFh'* ]]; then echo database >> "$TRACE"
        elif [[ "$value" == *'"name":"amisad-ledger-write"'* && "$value" == *'"token":"YmJi'* ]]; then echo ledger >> "$TRACE"
        else exit 19
        fi ;;
    'docker build -t '*) test -f "$4/Dockerfile" || exit 19; echo image >> "$TRACE" ;;
    'docker save '*) [ "$#" -eq 11 ] || exit 19; echo 'ten image archive' ;;
    'helm upgrade --install '*) echo helm >> "$TRACE" ;;
    'kubectl -n amisad wait '*) echo wait >> "$TRACE" ;;
    'kubectl -n amisad patch svc '*) echo port >> "$TRACE" ;;
    *) printf 'Unexpected command: %s %s\n' "$name" "$*" >&2; exit 9 ;;
esac
"#;
    for tool in ["getent", "openssl", "sudo", "kubectl", "docker", "helm"] {
        let tool = tools.join(tool);
        fs::write(&tool, fake).unwrap();
        fs::set_permissions(tool, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let search = env::join_paths(
        std::iter::once(tools).chain(env::split_paths(&env::var_os("PATH").unwrap())),
    )
    .unwrap();
    let trace = path.join("trace");
    let result = Command::new(env!("CARGO_BIN_EXE_amisad-provision"))
        .arg("core-deploy")
        .current_dir(path)
        .env("PATH", search)
        .env("TRACE", &trace)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{:?}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(String::from_utf8_lossy(&result.stdout).contains("amisad-core DEPLOY PASSED"));
    assert!(!String::from_utf8_lossy(&result.stdout).contains("a".repeat(48).as_str()));
    let order = fs::read_to_string(trace).unwrap();
    let calls: Vec<_> = order.lines().collect();
    assert!(calls[..2].contains(&"api-ready"));
    assert!(calls[..2].contains(&"pg-ready"));
    assert_eq!(
        &calls[2..8],
        &[
            "namespace",
            "sql",
            "delete amisad-database",
            "database",
            "delete amisad-ledger-write",
            "ledger"
        ]
    );
    assert_eq!(&calls[8..18], &["image"; 10]);
    assert_eq!(calls[18], "import");
    assert_eq!(&calls[19..29], &["helm"; 10]);
    assert_eq!(&calls[29..39], &["wait"; 10]);
    assert_eq!(&calls[39..49], &["port"; 10]);
}

#[test]
fn deploys_skeletons_through_a_loopback_registry_and_exact_image_paths() {
    let _fixture = FIXTURE_TOOLS.lock().unwrap();
    let directory = Command::new("mktemp")
        .args(["-dt", "amisad-skeletons.XXXXXXXX"])
        .output()
        .unwrap();
    assert!(directory.status.success());
    let scratch = Scratch(PathBuf::from(
        String::from_utf8(directory.stdout).unwrap().trim(),
    ));
    let tools = scratch.0.join("bin");
    fs::create_dir(&tools).unwrap();
    let poc = scratch.0.join("git/yuruna/project/poc");
    fs::create_dir_all(&poc).unwrap();
    let fake = r#"#!/bin/bash
name=${0##*/}
case "$name $*" in
    'getent -- passwd '*) printf 'fixture:x:%s:%s::%s:/bin/bash\n' "$3" "$3" "$FIXTURE" ;;
    'getent passwd fixture') printf 'fixture:x:1000:1000::%s:/bin/bash\n' "$FIXTURE" ;;
    'sudo -n chown -R -- fixture:fixture '*) echo ownership >> "$TRACE" ;;
    'docker container inspect --format {{json .}} registry')
        printf '{"Id":"%064d","HostConfig":{"PortBindings":{"5000/tcp":[{"HostIp":"%s"}]}}}\n' 0 "$BINDING" ;;
    'docker start '*) test "${#2}" -eq 64 || exit 19; echo start >> "$TRACE" ;;
    'docker rm -f '*) test "${#3}" -eq 64 || exit 19; echo remove >> "$TRACE" ;;
    'docker run -d -p 127.0.0.1:5000:5000 --restart=always --name registry registry:2.8.3')
        echo loopback >> "$TRACE" ;;
    'docker build -f components/services/'*) test "$PWD" = "$FIXTURE/git/yuruna/project/poc" || exit 19
        printf 'build %s %s\n' "$3" "$5" >> "$TRACE" ;;
    'docker push localhost:5000/amisad/'*) printf 'push %s\n' "$2" >> "$TRACE" ;;
    'helm upgrade --install '*) printf 'chart %s %s\n' "$3" "$9" >> "$TRACE" ;;
    'kubectl -n amisad get deployments') printf 'NAME READY\n'; echo report >> "$TRACE" ;;
    *) printf 'Unexpected command: %s %s\n' "$name" "$*" >&2; exit 9 ;;
esac
"#;
    for file in ["getent", "sudo", "kubectl", "docker", "helm"] {
        let path = tools.join(file);
        fs::write(&path, fake).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let trace = scratch.0.join("trace");
    for (binding, replacement) in [("0.0.0.0", true), ("127.0.0.1", false)] {
        fs::write(&trace, "").unwrap();
        let result = Command::new(env!("CARGO_BIN_EXE_amisad-provision"))
            .arg("core-deploy-skeletons")
            .env_clear()
            .env("PATH", &tools)
            .env("USER", "fixture")
            .env("FIXTURE", &scratch.0)
            .env("BINDING", binding)
            .env("TRACE", &trace)
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        let calls = fs::read_to_string(&trace).unwrap();
        assert_eq!(calls.contains("loopback\n"), replacement);
        assert_eq!(calls.contains("remove\n"), replacement);
        assert_eq!(calls.contains("start\n"), !replacement);
        assert_eq!(
            calls
                .lines()
                .filter(|line| line.starts_with("chart "))
                .count(),
            10
        );
        assert!(calls.contains(concat!(
            "build components/services/seller-svc/Dockerfile localhost:5000/amisad/seller-svc:latest\n",
            "push localhost:5000/amisad/seller-svc:latest\n",
            "chart seller-svc image=localhost:5000/amisad/seller-svc:latest\n",
        )));
        assert!(calls.ends_with("\nreport\n"));
        assert!(String::from_utf8_lossy(&result.stdout)
            .contains("NAME READY\nAmisAd POC skeletons deployed"));
    }
}
