defmodule OCI.Plug do
  @moduledoc """
  A Plug for handling OCI (Open Container Initiative) requests.
  """

  @behaviour Plug
  import Plug.Conn
  alias OCI.Registry

  @api_version OCI.Registry.api_version()

  @impl true
  def init(opts) do
    registry =
      case Keyword.get(opts, :registry) do
        nil -> OCI.Registry.from_app_env()
        registry -> registry
      end

    %{registry: registry}
  end

  @impl true
  def call(%{script_name: [@api_version]} = conn, %{registry: registry}) do
    conn =
      conn
      |> ensure_request_id()
      |> put_private(:oci_registry, registry)
      |> authenticate()

    case authorize(conn) do
      :ok ->
        max_body_size = max(registry.max_manifest_size, registry.max_blob_upload_chunk_size)
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: max_body_size)

        # Reverse the path info, and the last parts after the known API path portions is the repo name.
        # V2 is plucked off by the "script_name" when scope/forwarding from Phoenix
        segments = conn.path_info |> Enum.reverse()

        # TODO: remove the debug inspector and a note about its use.
        conn
        |> assign(:raw_body, body)
        |> fetch_query_params()
        |> OCI.Inspector.inspect("before:handle_request/1")
        |> OCI.Plug.Handler.handle(segments)

      {:error, :UNAUTHORIZED} ->
        challenge(conn)
    end
  end

  def call(conn, _opts) do
    error_resp(conn, :UNSUPPORTED, "OCI Registry must be mounted at /#{Registry.api_version()}")
  end

  defp error_resp(conn, code, details \\ nil) do
    error = OCI.Error.init(code, details)
    body = %{errors: [error]} |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.http_status, body)
    |> halt()
  end

  defp ensure_request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [] ->
        id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

        conn
        |> put_req_header("x-request-id", id)
        |> put_resp_header("x-request-id", id)
        |> put_private(:plug_request_id, id)

      [existing_id | _] ->
        put_private(conn, :plug_request_id, existing_id)
    end
  end

  def authenticate(%{private: %{oci_registry: registry}} = conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> List.first()
    |> case do
      nil ->
        conn

      authorization ->
        case Registry.authenticate(registry, authorization) do
          {:ok, ctx} ->
            conn
            |> assign(:oci_ctx, ctx)

          {:error, reason} ->
            error_resp(conn, reason)
        end
    end
  end

  defp authorize(%{private: %{oci_registry: registry}, assigns: %{oci_ctx: ctx}}) do
    # TODO: infer and pass authorization info, pass repo as well
    # TODO: pass auth adapter to adapter functions and make sure auth tests fail when i change password to $myp$$$ or something.
    Registry.authorize(registry, ctx, "TODO:ACTION", "TODO:RESOURCE")
  end

  defp authorize(_) do
    {:error, :UNAUTHORIZED}
  end

  defp challenge(conn) do
    registry = conn.private[:oci_registry]
    {scheme, auth_param} = Registry.challenge(registry)

    conn
    |> put_resp_header("www-authenticate", "#{scheme} #{auth_param}")
    |> send_resp(401, "")
    |> halt
  end
end
