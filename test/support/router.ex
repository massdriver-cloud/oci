defmodule TestRegistryWeb do
  @moduledoc false
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

    plug(Plug.Parsers,
      parsers: [OCI.Plug.Parser, :json],
      pass: ["*/*"],
      json_decoder: Jason,
      length: 20_000_000
    )

    plug(TestRegistryWeb.Router)
  end

  defmodule ErrorView do
    def render(conn, error) do
      require IEx
      IEx.pry()
    end
  end
end
