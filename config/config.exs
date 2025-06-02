import Config
config :logger, level: :info

config :oci,
  auth: %{
    adapter: OCI.Auth.Static,
    config: %{
      users: [
        %{
          username: "myuser",
          password: "mypass",
          permissions: %{"myimage" => ["pull", "push"]}
        }
      ]
    }
  },
  storage: %{
    adapter: OCI.Storage.Local,
    config: %{
      path: "./tmp/"
    }
  }
