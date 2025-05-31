defmodule TestRegistryWeb do
  defmodule Router do
    @moduledoc false
    use Phoenix.Router

    forward("/v2", OCI.Plug, [])
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :oci

    plug(TestRegistryWeb.Router)
  end
end
