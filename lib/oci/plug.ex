defmodule OCI.Plug do
  @moduledoc """
  A Plug for handling OCI (Open Container Initiative) requests.
  """

  @behaviour Plug
  import Plug.Conn
  alias OCI.Registry
  alias OCI.Registry.Pagination

  @api_version OCI.Registry.api_version()

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry)

    registry =
      if registry do
        registry
      else
        # Try to get storage config from application config
        case Application.get_env(:oci, :storage) do
          nil ->
            raise "No registry provided and no storage config found in application config"

          storage_config ->
            adapter = Keyword.get(storage_config, :adapter)
            config = Keyword.get(storage_config, :config)

            if adapter && config do
              OCI.Registry.init(storage: adapter.init(config))
            else
              raise "Invalid storage config in application config"
            end
        end
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

        # TODO: remove the debug inspector and a note about its use.
        conn
        |> assign(:raw_body, body)
        |> fetch_query_params()
        |> OCI.Inspector.inspect("before:handle_request/1")
        |> handler()

      {:error, :UNAUTHORIZED} ->
        challenge(conn)
    end
  end

  def call(conn, _opts) do
    error_resp(conn, :UNSUPPORTED, "OCI Registry must be mounted at /#{Registry.api_version()}")
  end

  defp handler(conn) do
    # Reverse the path info, and the last parts after the known API path portions is the repo name.
    # V2 is plucked off by the "script_name" when scope/forwarding from Phoenix
    conn.path_info
    |> Enum.reverse()
    |> case do
      [] ->
        case conn.method do
          "GET" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, "{}")

          _ ->
            error_resp(conn, :UNSUPPORTED)
        end

      ["list", "tags" | rest] ->
        repo = rest |> Enum.reverse() |> Enum.join("/")

        case conn.method do
          "GET" -> list_tags(conn, repo)
          _ -> error_resp(conn, :UNSUPPORTED)
        end

      ["uploads", "blobs" | rest] ->
        repo = rest |> Enum.reverse() |> Enum.join("/")

        case conn.method do
          "POST" -> initiate_blob_upload(conn, repo)
          _ -> error_resp(conn, :UNSUPPORTED)
        end

      [uuid, "uploads", "blobs" | rest] ->
        repo = rest |> Enum.reverse() |> Enum.join("/")

        case conn.method do
          "PATCH" -> upload_chunk(conn, repo, uuid)
          "GET" -> get_upload_status(conn, repo, uuid)
          "PUT" -> complete_blob_upload(conn, repo, uuid)
          "DELETE" -> cancel_blob_upload(conn, repo, uuid)
          _ -> error_resp(conn, :UNSUPPORTED)
        end

      [digest, "blobs" | rest] ->
        repo = rest |> Enum.reverse() |> Enum.join("/")

        case conn.method do
          "HEAD" -> head_blob(conn, repo, digest)
          "GET" -> get_blob(conn, repo, digest)
          "DELETE" -> delete_blob(conn, repo, digest)
          _ -> error_resp(conn, :UNSUPPORTED)
        end

      [reference, "manifests" | rest] ->
        repo = rest |> Enum.reverse() |> Enum.join("/")

        case conn.method do
          "PUT" -> put_manifest(conn, repo, reference)
          "GET" -> get_manifest(conn, repo, reference)
          "HEAD" -> head_manifest(conn, repo, reference)
          "DELETE" -> delete_manifest(conn, repo, reference)
          _ -> error_resp(conn, :UNSUPPORTED)
        end

      _ ->
        error_resp(conn, :UNSUPPORTED)
    end
  end

  # Cross-repo mounting
  defp initiate_blob_upload(%{query_params: %{"mount" => mount, "from" => from}} = conn, repo) do
    registry = conn.private[:oci_registry]

    case Registry.mount_blob(registry, repo, mount, from) do
      {:ok, location} ->
        case String.match?(location, ~r{/blobs/uploads/}) do
          true ->
            conn
            |> put_resp_header("location", location)
            |> send_resp(202, "")

          false ->
            conn
            |> put_resp_header("location", location)
            |> send_resp(201, "")
        end

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  # Monolithic POST
  defp initiate_blob_upload(%{query_params: %{"digest" => digest}} = conn, repo) do
    registry = conn.private[:oci_registry]

    case Registry.initiate_blob_upload(registry, repo) do
      {:ok, location} ->
        upload_id = location |> String.split("/") |> List.last()
        chunk = conn.assigns[:raw_body]

        case Registry.upload_chunk(
               registry,
               repo,
               upload_id,
               chunk,
               nil
             ) do
          {:ok, _, _} ->
            :ok

          {:error, oci_error_status} ->
            error_resp(conn, oci_error_status)
        end

        case Registry.complete_blob_upload(
               registry,
               repo,
               upload_id,
               digest
             ) do
          {:ok, location} ->
            conn
            |> put_resp_header("location", location)
            |> send_resp(201, "")

          {:error, oci_error_status} ->
            error_resp(conn, oci_error_status)
        end

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  # Create a chunked upload session
  defp initiate_blob_upload(conn, repo) do
    registry = conn.private[:oci_registry]

    case Registry.initiate_blob_upload(registry, repo) do
      {:ok, location} ->
        conn
        |> put_resp_header("location", location)
        |> send_resp(202, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp put_manifest(conn, repo, reference) do
    registry = conn.private[:oci_registry]
    manifest = conn.assigns[:raw_body]

    content_type = get_req_header(conn, "content-type") |> List.first()

    case Registry.put_manifest(registry, repo, reference, manifest, content_type) do
      {:ok, _digest} ->
        conn
        |> put_resp_header("location", Registry.manifests_reference_path(repo, reference))
        |> send_resp(201, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  # https://github.com/opencontainers/distribution-spec/pull/576
  # PR to fix conformance test suite to properly test Content-Range requirement
  # for PATCH requests as specified in the spec. The spec requires Content-Range
  # for PATCH requests to ensure ordered chunk uploads, but the test suite
  # incorrectly omits this requirement. The spec requires:
  # - Content-Range header is required for PATCH requests
  # - Must be inclusive on both ends (e.g. "0-1023")
  # - First chunk must begin with 0
  # - Must match regex ^[0-9]+-[0-9]+$
  defp upload_chunk(conn, repo, uuid) do
    content_range = conn |> get_req_header("content-range") |> List.first()

    case content_range do
      nil ->
        error_resp(
          conn,
          :BLOB_UPLOAD_INVALID,
          "Content-Range header is required for PATCH requests"
        )

      _ ->
        registry = conn.private[:oci_registry]
        chunk = conn.assigns[:raw_body]

        case Registry.upload_chunk(registry, repo, uuid, chunk, content_range) do
          {:ok, location, range} ->
            conn
            |> put_resp_header("location", location)
            |> put_resp_header("range", range)
            |> send_resp(202, "")

          {:error, oci_error_status} ->
            error_resp(conn, oci_error_status)
        end
    end
  end

  defp get_upload_status(conn, repo, uuid) do
    registry = conn.private[:oci_registry]

    case Registry.get_upload_status(registry, repo, uuid) do
      {:ok, location, range} ->
        conn
        |> put_resp_header("location", location)
        |> put_resp_header("range", range)
        |> send_resp(204, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  # The closing `PUT` request MUST include the `<digest>` of the whole blob (not the final chunk) as a query parameter.
  defp complete_blob_upload(%{query_params: %{"digest" => digest}} = conn, repo, uuid)
       when not is_nil(digest) do
    registry = conn.private[:oci_registry]

    # Must have a content-length, it may be 0 depending on if a final chunk is being uploaded or not with the digest.
    content_length =
      conn |> get_req_header("content-length") |> List.first() |> String.to_integer()

    if content_length > 0 do
      case Registry.upload_chunk(
             registry,
             repo,
             uuid,
             conn.assigns[:raw_body],
             nil
           ) do
        {:ok, _, _} ->
          :ok

        {:error, oci_error_status} ->
          error_resp(conn, oci_error_status)
      end
    end

    case Registry.complete_blob_upload(registry, repo, uuid, digest) do
      {:ok, location} ->
        conn
        |> put_resp_header("location", location)
        |> send_resp(201, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp complete_blob_upload(conn, _repo, _uuid) do
    error_resp(
      conn,
      :DIGEST_INVALID,
      "Digest query parameter is required for PUT requests"
    )
  end

  defp cancel_blob_upload(conn, repo, uuid) do
    registry = conn.private[:oci_registry]

    case Registry.cancel_blob_upload(registry, repo, uuid) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp head_blob(conn, repo, digest) do
    registry = conn.private[:oci_registry]

    case Registry.blob_exists?(registry, repo, digest) do
      {:ok, size} ->
        conn
        |> put_resp_header("content-length", "#{size}")
        |> send_resp(200, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp get_blob(conn, repo, digest) do
    registry = conn.private[:oci_registry]

    case Registry.get_blob(registry, repo, digest) do
      {:ok, content} ->
        conn
        |> put_resp_header("content-length", "#{byte_size(content)}")
        |> send_resp(200, content)

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp delete_blob(conn, repo, digest) do
    registry = conn.private[:oci_registry]

    case Registry.delete_blob(registry, repo, digest) do
      :ok ->
        send_resp(conn, 202, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp get_manifest(conn, repo, reference) do
    registry = conn.private[:oci_registry]

    case Registry.get_manifest(registry, repo, reference) do
      {:ok, manifest, content_type, _digest} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> send_resp(200, manifest)

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp head_manifest(conn, repo, reference) do
    registry = conn.private[:oci_registry]

    case Registry.head_manifest(registry, repo, reference) do
      {:ok, content_type, _digest, size} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("content-length", "#{size}")
        |> send_resp(200, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp delete_manifest(conn, repo, reference) do
    case Registry.delete_manifest(conn.private[:oci_registry], repo, reference) do
      :ok ->
        conn
        |> put_status(202)
        |> send_resp(202, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp list_tags(conn, repo) do
    registry = conn.private[:oci_registry]

    case Registry.list_tags(registry, repo, pagination(conn.query_params)) do
      {:ok, tags} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{name: repo, tags: tags}))

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp error_resp(conn, code, details \\ nil) do
    error = OCI.Error.init(code, details)
    body = %{errors: [error]} |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.http_status, body)
    |> halt()
  end

  defp pagination(params) do
    n = if params["n"], do: String.to_integer(params["n"]), else: nil
    last = params["last"]

    %Pagination{n: n, last: last}
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

  defp get_authorization_header(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> List.first()
  end

  def authenticate(conn) do
    conn
    |> get_authorization_header()
    |> case do
      nil ->
        conn

      authorization ->
        authorization
        |> OCI.Auth.Adapter.authenticate()
        |> case do
          {:ok, ctx} ->
            conn
            |> assign(:oci_ctx, ctx)

          {:error, reason} ->
            error_resp(conn, reason)
        end
    end
  end

  defp authorize(%{assigns: %{oci_ctx: ctx}}) do
    # TODO: infer and pass authorization info
    OCI.Auth.Adapter.authorize(ctx, "TODO:ACTION", "TODO:RESOURCE")
  end

  defp authorize(_) do
    {:error, :UNAUTHORIZED}
  end

  defp challenge(conn) do
    registry = conn.private[:oci_registry]
    {scheme, auth_param} = OCI.Auth.Adapter.challenge(registry)

    conn
    |> put_resp_header("www-authenticate", "#{scheme} #{auth_param}")
    |> send_resp(401, "")
    |> halt
  end
end
