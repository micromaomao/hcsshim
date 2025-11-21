package fragment

svn := "1"
framework_version := "0.5.0"

containers := [
  {
    @@CONTAINER_COMMON@@
    "command": [
      "bash"
    ],
    "env_rules": [
      {
        "name": "Fabric_NodeIPOrFqdn",
        "name_strategy": "string",
        "value": "10.0.0.1",
        "value_strategy": "string",
        "required": true
      }
    ],
    "exec_processes": [],
    "layers": [
      "0000000000000000000000000000000000000000000000000000000000000000"
    ],
    "mounts": [
      {
        "destination": "/var/run/secrets/kubernetes.io/serviceaccount",
        "options": [
          "rbind",
          "rshared",
          "ro"
        ],
        "source": "sandbox:///tmp/atlas/emptydir/.+",
        "type": "bind"
      }
    ]
  }
]
