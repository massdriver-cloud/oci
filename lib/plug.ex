defmodule OCI.Plug do
  @moduledoc """
  A Plug for handling OCI (Open Container Initiative) requests.
  """

  @behaviour Plug
  import Plug.Conn
  alias OCI.Registry
  alias OCI.Registry.Pagination

  @error_codes %{
    BLOB_UNKNOWN: "blob unknown to registry",
    BLOB_UPLOAD_INVALID: "blob upload invalid",
    BLOB_UPLOAD_UNKNOWN: "blob upload unknown to registry",
    DIGEST_INVALID: "provided digest did not match uploaded content",
    MANIFEST_BLOB_UNKNOWN: "manifest references a manifest or blob unknown to registry",
    MANIFEST_INVALID: "manifest invalid",
    MANIFEST_UNKNOWN: "manifest unknown to registry",
    NAME_INVALID: "invalid repository name",
    NAME_UNKNOWN: "repository name not known to registry",
    SIZE_INVALID: "provided length did not match content length",
    UNAUTHORIZED: "authentication required",
    DENIED: "requested access to the resource is denied",
    UNSUPPORTED: "the operation is unsupported",
    TOOMANYREQUESTS: "too many requests"
  }

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

  @impl true
  def call(conn, %{registry: registry}) do
    conn =
      conn
      |> ensure_request_id()
      |> put_private(:oci_registry, registry)
      |> authenticate()

    case authorize(conn) do
      :ok ->
        max_body_size = max(registry.max_manifest_size, registry.max_blob_upload_chunk_size)
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: max_body_size)

        conn
        |> assign(:raw_body, body)
        |> fetch_query_params()
        |> OCI.Inspector.inspect("before:handle_request/1")
        |> handle_request()

      {:error, :UNAUTHORIZED} ->
        challenge(conn)
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

  defp handle_request(%{path_info: ["v2"]} = conn), do: ping(conn)
  defp handle_request(%{path_info: ["v2" | _]} = conn), do: handle_v2(conn)
  defp handle_request(conn), do: error_resp(conn, :UNSUPPORTED)

  defp handle_v2(conn) do
    [_v2 | segments] = conn.path_info

    segments
    |> Enum.reverse()
    |> case do
      ["list", "tags" | repo] ->
        repo = repo |> Enum.reverse() |> Enum.join("/")
        list_tags(conn, repo)

      ["uploads", "blobs" | repo] ->
        repo = repo |> Enum.reverse() |> Enum.join("/")
        initiate_blob_upload(conn, repo)

      [uuid, "uploads", "blobs" | repo] ->
        repo = repo |> Enum.reverse() |> Enum.join("/")

        case conn.method do
          "PATCH" -> upload_chunk(conn, repo, uuid)
          "GET" -> get_upload_status(conn, repo, uuid)
          "PUT" -> complete_blob_upload(conn, repo, uuid)
          "DELETE" -> cancel_blob_upload(conn, repo, uuid)
          _ -> error_resp(conn, :UNSUPPORTED)
        end

      [digest, "blobs" | repo] ->
        repo = repo |> Enum.reverse() |> Enum.join("/")

        case conn.method do
          "HEAD" -> head_blob(conn, repo, digest)
          "GET" -> get_blob(conn, repo, digest)
          "DELETE" -> delete_blob(conn, repo, digest)
          _ -> error_resp(conn, :UNSUPPORTED)
        end

      [reference, "manifests" | repo] ->
        repo = repo |> Enum.reverse() |> Enum.join("/")

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
               "0-#{String.length(chunk) - 1}"
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
        |> put_resp_header("location", "/v2/#{repo}/manifests/#{reference}")
        |> send_resp(201, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  defp upload_chunk(conn, repo, uuid) do
    registry = conn.private[:oci_registry]
    chunk = conn.assigns[:raw_body]
    # TODO: DONT CALCULATE CONTENT RANGE, SEND SIZE
    content_range = calculate_content_range(conn)

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

  defp get_upload_status(conn, repo, uuid) do
    registry = conn.private[:oci_registry]

    case Registry.get_upload_status(registry, repo, uuid) do
      {:ok, range} ->
        conn
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

    # Maybe I shouldn't touch it on create?
    # What chunks have i received?

    # Must have a content-length, it maybe 0
    content_length =
      conn |> get_req_header("content-length") |> List.first() |> String.to_integer()

    if content_length > 0 do
      case Registry.upload_chunk(
             registry,
             repo,
             uuid,
             conn.assigns[:raw_body],
             content_length
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
    error_resp(conn, :DIGEST_INVALID)
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

  defp ping(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, "{}")
  end

  defp error_resp(conn, code, details \\ nil) do
    body =
      %{
        errors: [
          %{
            code: code,
            message: @error_codes[code],
            detail: details
          }
        ]
      }
      |> Jason.encode!()

    status =
      case code do
        :BLOB_UNKNOWN ->
          404

        :BLOB_UPLOAD_INVALID ->
          400

        :BLOB_UPLOAD_UNKNOWN ->
          404

        :DIGEST_INVALID ->
          400

        :MANIFEST_BLOB_UNKNOWN ->
          400

        :MANIFEST_INVALID ->
          400

        :MANIFEST_UNKNOWN ->
          404

        :NAME_INVALID ->
          400

        :NAME_UNKNOWN ->
          404

        :SIZE_INVALID ->
          400

        :UNAUTHORIZED ->
          401

        :DENIED ->
          403

        :UNSUPPORTED ->
          405

        :TOOMANYREQUESTS ->
          429

        _ ->
          500
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  defp pagination(params) do
    n = if params["n"], do: String.to_integer(params["n"]), else: nil
    last = params["last"]

    %Pagination{n: n, last: last}
  end

  defp calculate_content_range(conn) do
    conn
    |> get_req_header("content-range")
    |> List.first()
    |> case do
      nil ->
        get_req_header(conn, "content-length")
        |> List.first()
        |> case do
          nil ->
            nil

          "0" ->
            "0-0"

          content_length ->
            length = String.to_integer(content_length)
            "0-#{length - 1}"
        end

      content_range ->
        content_range
    end
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
