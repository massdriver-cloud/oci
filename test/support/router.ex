defmodule TestRegistryWeb do
  defmodule Router do
    @moduledoc false
    use Phoenix.Router

    scope "/v2" do
      forward("/", OCI.Plug, [])
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :oci

    plug(TestRegistryWeb.Router)
  end
end
