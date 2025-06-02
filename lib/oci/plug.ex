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
    conn
    |> set_context()
    |> ensure_request_id()
    |> put_private(:oci_registry, registry)
    |> authenticate()
    |> fetch_query_params()
    |> set_raw_body()
    |> authorize()
    |> OCI.Inspector.inspect("before:handle/1")
    |> OCI.Plug.Handler.handle()
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

  defp set_context(conn) do
    segments = conn.path_info |> Enum.reverse()

    {rest, endpoint, id} =
      case segments do
        [] -> {[], :ping, nil}
        ["list", "tags" | rest] -> {rest, :tags_list, nil}
        ["uploads", "blobs" | rest] -> {rest, :blobs_uploads, nil}
        [uuid, "uploads", "blobs" | rest] -> {rest, :blobs_uploads, uuid}
        [digest, "blobs" | rest] -> {rest, :blobs, digest}
        [reference, "manifests" | rest] -> {rest, :manifests, reference}
      end

    # Reverse the path info, and the last parts after the known API path portions is the repo name.
    # V2 is plucked off by the "script_name" when scope/forwarding from Phoenix
    repo = rest |> Enum.reverse() |> Enum.join("/")

    ctx = %OCI.Context{
      subject: nil,
      endpoint: endpoint,
      resource: id,
      repo: repo,
      method: conn.method
    }

    conn |> assign(:oci_ctx, ctx)
  end

  defp error_resp(conn, code, details) do
    error = OCI.Error.init(code, details)
    body = %{errors: [error]} |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.http_status, body)
    |> halt()
  end

  # Don't bother reading the body if we're already halted
  defp set_raw_body(%{halted: true} = conn), do: conn

  defp set_raw_body(%{private: %{oci_registry: registry}} = conn) do
    max_body_size = max(registry.max_manifest_size, registry.max_blob_upload_chunk_size)
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: max_body_size)
    assign(conn, :raw_body, body)
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
end
