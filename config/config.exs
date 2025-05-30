import Config
config :logger, level: :info

config :oci,
  storage: [
    adapter: OCI.Storage.Local,
    config: [
      path: "./tmp/"
    ]
  ]
