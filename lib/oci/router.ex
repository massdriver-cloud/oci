defmodule OCI.Router do
  @moduledoc """
  A Plug.Router for the OCI service.

  ## Configuration Options

    * `:adapter` - The storage adapter to use. Must be one of `:memory` or `:s3`. (required)
    * `:adapter_opts` - Options for the adapter. (optional, map)
    * `:log_level` - Logger level for Plug.Logger. Defaults to :info. (optional)
    * `:other_opts` - Any other options to pass to Plug or your application. (optional)

  Example:

      plug OCI.Router, adapter: :memory, adapter_opts: %{foo: :bar}, log_level: :debug
  """

  use Plug.Router
  use Plug.ErrorHandler

  @impl true
  def init(opts) do
    adapter = Keyword.get(opts, :adapter)

    unless adapter in [:memory, :s3] do
      raise ArgumentError, "Invalid :adapter option. Must be one of [:memory, :s3]"
    end

    opts
  end

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  # Example route
  get "/" do
    send_resp(conn, 200, "Welcome to the OCI Plug Router!")
  end

  # Catch-all for unmatched routes
  match _ do
    send_resp(conn, 404, "Not found")
  end

  # Error handlers
  defp handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    send_resp(conn, conn.status, "Something went wrong")
  end
end
