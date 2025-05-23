defmodule OCI do
  @moduledoc """
  Documentation for `OCI`.
  """

  @doc """
  Starts the OCI Plug router on the given port.
  """
  def child_spec(opts \\ []) do
    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: OCI.Router,
      options: [port: opts[:port] || 4000]
    )
  end
end
