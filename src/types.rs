//! Re-export canonical types from the orch crate.
//!
//! orchd depends on orch as a library to get compile-time alignment
//! between the parser's JSON output and the engine's deserialization.

pub use orch::types::*;

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;

    fn stub_minimal_json() -> &'static str {
        r#"{
            "version": "0.2.0",
            "services": [
                {
                    "name": "web",
                    "mode": "host",
                    "run_command": "/usr/bin/nginx",
                    "oneshot": false,
                    "disabled": false,
                    "recreate": "never",
                    "restart": {"policy": "no"},
                    "timeouts": {},
                    "resources": {},
                    "logging": {}
                }
            ]
        }"#
    }

    fn stub_full_service_json() -> &'static str {
        r#"{
            "version": "0.2.0",
            "args": {"FOO": "bar"},
            "services": [
                {
                    "name": "api",
                    "mode": "container",
                    "image": "myapp:latest",
                    "entrypoint": "/entrypoint.sh",
                    "cmd": "serve",
                    "publish": [{"host": 8080, "container": 80}],
                    "volumes": [{"source": "/data", "destination": "/app/data", "is_named": false}],
                    "env": {"DB_HOST": "localhost"},
                    "env_files": [".env"],
                    "requires": ["postgres"],
                    "after": ["postgres"],
                    "healthcheck": "curl -sf http://localhost:8080/health",
                    "readiness_timeout": "30s",
                    "oneshot": false,
                    "disabled": false,
                    "recreate": "always",
                    "restart": {
                        "policy": "on_failure",
                        "delay": "5s",
                        "start_limit_burst": 3,
                        "start_limit_interval": "60s"
                    },
                    "timeouts": {"start": "30s", "stop": "10s"},
                    "resources": {
                        "memory": "512M",
                        "cpus": 2.0,
                        "limit_nofile": 65536
                    },
                    "logging": {"stdout": "journal", "stderr": "journal"}
                }
            ]
        }"#
    }

    #[test]
    fn test_deserialize__minimal_orchfile() {
        let orchfile: OrchFile = serde_json::from_str(stub_minimal_json()).unwrap();
        assert_eq!(orchfile.version, "0.2.0");
        assert_eq!(orchfile.services.len(), 1);
        assert_eq!(orchfile.services[0].name, "web");
        assert!(orchfile.services[0].is_host());
    }

    #[test]
    fn test_deserialize__full_service() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        let svc = &orchfile.services[0];
        assert_eq!(svc.name, "api");
        assert_eq!(svc.mode, ServiceMode::Container);
        assert!(svc.is_container());
        assert!(!svc.is_host());
        assert_eq!(svc.image.as_deref(), Some("myapp:latest"));
        assert_eq!(svc.entrypoint.as_deref(), Some("/entrypoint.sh"));
        assert_eq!(svc.cmd.as_deref(), Some("serve"));
        assert_eq!(svc.publish.len(), 1);
        assert_eq!(svc.publish[0].host, 8080);
        assert_eq!(svc.volumes.len(), 1);
        assert_eq!(svc.env.get("DB_HOST").unwrap(), "localhost");
        assert_eq!(svc.env_files, vec![".env"]);
        assert_eq!(svc.requires, vec!["postgres"]);
        assert_eq!(svc.after, vec!["postgres"]);
        assert_eq!(
            svc.healthcheck.as_deref(),
            Some("curl -sf http://localhost:8080/health")
        );
        assert_eq!(svc.readiness_timeout.as_deref(), Some("30s"));
        assert!(!svc.oneshot);
        assert!(!svc.disabled);
        assert_eq!(svc.recreate, RecreatePolicy::Always);
    }

    #[test]
    fn test_deserialize__restart_config() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        let restart = &orchfile.services[0].restart;
        assert_eq!(restart.policy, RestartPolicy::OnFailure);
        assert_eq!(restart.delay.as_deref(), Some("5s"));
        assert_eq!(restart.start_limit_burst, Some(3));
        assert_eq!(restart.start_limit_interval.as_deref(), Some("60s"));
    }

    #[test]
    fn test_deserialize__timeout_config() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        let timeouts = &orchfile.services[0].timeouts;
        assert_eq!(timeouts.start.as_deref(), Some("30s"));
        assert_eq!(timeouts.stop.as_deref(), Some("10s"));
    }

    #[test]
    fn test_deserialize__resource_limits() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        let res = &orchfile.services[0].resources;
        assert_eq!(res.memory.as_deref(), Some("512M"));
        assert_eq!(res.cpus, Some(2.0));
        assert_eq!(res.limit_nofile, Some(65536));
    }

    #[test]
    fn test_deserialize__args_map() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        assert_eq!(orchfile.args.get("FOO").unwrap(), "bar");
    }

    #[test]
    fn test_deserialize__defaults_when_missing() {
        let json = r#"{
            "version": "0.1.0",
            "services": [
                {
                    "name": "svc",
                    "mode": "host",
                    "oneshot": false,
                    "disabled": false,
                    "recreate": "never",
                    "restart": {"policy": "no"},
                    "timeouts": {},
                    "resources": {},
                    "logging": {}
                }
            ]
        }"#;
        let orchfile: OrchFile = serde_json::from_str(json).unwrap();
        let svc = &orchfile.services[0];
        assert!(orchfile.args.is_empty());
        assert!(svc.env.is_empty());
        assert!(svc.env_files.is_empty());
        assert!(svc.requires.is_empty());
        assert!(svc.after.is_empty());
        assert!(svc.publish.is_empty());
        assert!(svc.volumes.is_empty());
        assert!(!svc.oneshot);
        assert!(!svc.disabled);
        assert_eq!(svc.restart.policy, RestartPolicy::No);
        assert_eq!(svc.recreate, RecreatePolicy::Never);
    }

    #[test]
    fn test_is_host__returns_true_for_host_mode() {
        let orchfile: OrchFile = serde_json::from_str(stub_minimal_json()).unwrap();
        assert!(orchfile.services[0].is_host());
        assert!(!orchfile.services[0].is_container());
    }

    #[test]
    fn test_is_container__returns_true_for_container_mode() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        assert!(orchfile.services[0].is_container());
        assert!(!orchfile.services[0].is_host());
    }
}
