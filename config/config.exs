import Config
config :logger, level: :info

config :oci,
  auth: %{
    adapter: OCI.Auth.StaticAuth,
    config: %{}
  },
  storage: %{
    adapter: OCI.Storage.Local,
    config: %{
      path: "./tmp/"
    }
  }
