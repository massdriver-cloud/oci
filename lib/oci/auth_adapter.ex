defmodule OCI.AuthAdapter do
  @moduledoc "Behaviour for pluggable authentication/authorization."
  @callback authenticate(conn :: Plug.Conn.t(), repo :: String.t() | nil, action :: atom) ::
              :ok | {:error, :unauthorized | :denied}
end
