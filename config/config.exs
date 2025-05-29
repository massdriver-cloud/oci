import Config
config :logger, level: :info

config :oci, :json_library, Jason

config :oci,
  storage: [
    adapter: OCI.Storage.Local,
    config: [
      path: "./tmp/"
    ]
  ]
