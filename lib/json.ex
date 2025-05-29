defmodule OCI.JSON do
  @moduledoc """
  Thin wrapper for JSON encoding/decoding with pluggable backend.

  Defaults to Jason, but can be configured via:
    config :oci, :json_library, MyCustomJSON
  """

  @json_library Application.compile_env(:oci, :json_library, Jason)

  def decode(json, opts \\ []), do: @json_library.decode(json, opts)
  def encode(data, opts \\ []), do: @json_library.encode(data, opts)
end
