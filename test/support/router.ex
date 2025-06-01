defmodule TestRegistryWeb do
  @moduledoc false
  defmodule Router do
    @moduledoc false
    use Phoenix.Router

    def registry_opts do
      {:ok, tmp_path} = Temp.path()
      {:ok, storage} = OCI.Storage.Local.init(%{path: tmp_path})
      {:ok, auth} = OCI.Auth.StaticAuth.init(%{})
      {:ok, registry} = OCI.Registry.init(storage: storage, auth: auth)
      [registry: registry]
    end

    scope "/v2" do
      forward("/", OCI.Plug, registry_opts())
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :oci

    plug(TestRegistryWeb.Router)
  end
end
