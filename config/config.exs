import Config
config :logger, level: :info

config :oci,
  auth: %{
    adapter: OCI.Auth.Static,
    config: %{
      users: [
        %{username: "myuser", password: "mypass"}
      ]
    }
  },
  storage: %{
    adapter: OCI.Storage.Local,
    config: %{
      path: "./tmp/"
    }
  }
