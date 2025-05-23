defmodule OCI.Auth.NoAuth do
  @behaviour OCI.AuthAdapter
  @moduledoc "Open (no-op) auth adapter: allows all requests."
  def authenticate(_conn, _repo, _action), do: :ok
end
