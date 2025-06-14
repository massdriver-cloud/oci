defmodule OCI.Plug do
  @moduledoc """
  A Plug for handling OCI (Open Container Initiative) requests.
  """

  @behaviour Plug
  require Logger
  import Plug.Conn
  alias OCI.Registry

  @api_version OCI.Registry.api_version()

  @impl true
  def init(opts) do
    registry =
      case Keyword.get(opts, :registry) do
        nil -> OCI.Registry.load_from_env()
        registry -> registry
      end

    %{registry: registry}
  end

  @impl true
  def call(%{script_name: [@api_version]} = conn, %{registry: registry}) do
    conn
    |> OCI.Plug.Context.call()
    |> put_private(:oci_registry, registry)
    |> authenticate()
    |> fetch_query_params()
    |> authorize()
    # |> OCI.Inspector.log_info(nil, "before:handle/1")
    |> OCI.Inspector.inspect("before:handle/1")
    |> OCI.Plug.Handler.handle()

    # |> OCI.Inspector.log_info(nil, "after:handle/1")
  end

  def call(conn, _opts) do
    error_resp(conn, :UNSUPPORTED, "OCI Registry must be mounted at /#{Registry.api_version()}")
  end

  def authenticate(%{private: %{oci_registry: registry}} = conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> List.first()
    |> case do
      nil ->
        challenge_resp(conn)

      authorization ->
        case Registry.authenticate(registry, authorization) do
          {:ok, subject} ->
            updated_ctx = %{conn.assigns[:oci_ctx] | subject: subject}
            conn |> assign(:oci_ctx, updated_ctx)

          {:error, reason, details} ->
            error_resp(conn, reason, details)
        end
    end
  end

  defp authorize(%{halted: true} = conn), do: conn

  defp authorize(%{private: %{oci_registry: registry}, assigns: %{oci_ctx: ctx}} = conn) do
    case Registry.authorize(registry, ctx) do
      :ok ->
        conn

      {:error, reason} ->
        error_resp(conn, reason, nil)

      {:error, reason, details} ->
        error_resp(conn, reason, details)
    end
  end

  defp authorize(_) do
    {:error, :UNAUTHORIZED}
  end

  defp challenge_resp(conn) do
    registry = conn.private[:oci_registry]
    {scheme, auth_param} = Registry.challenge(registry)

    conn
    |> put_resp_header("www-authenticate", "#{scheme} #{auth_param}")
    |> send_resp(401, "")
    |> halt
  end

  defp error_resp(conn, code, details) do
    error = OCI.Error.init(code, details)
    body = %{errors: [error]} |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.http_status, body)
    |> halt()
  end
end
