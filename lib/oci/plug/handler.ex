# TODO:
# [ ] return name invalid if it doesnt match the pattern
defmodule OCI.Plug.Handler do
  import Plug.Conn
  alias OCI.Registry
  alias OCI.Registry.Pagination

  def handle(%{method: "GET"} = conn, []) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, "{}")
  end

  def handle(%{method: "GET"} = conn, ["list", "tags" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  # Cross-repo mounting
  def handle(%{method: "POST", query_params: %{"mount" => mount, "from" => from}} = conn, [
        "uploads",
        "blobs" | rest
      ]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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
  def handle(%{method: "POST", query_params: %{"digest" => digest}} = conn, [
        "uploads",
        "blobs" | rest
      ]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  # Initiate a chunked blob upload session
  def handle(%{method: "POST"} = conn, ["uploads", "blobs" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  # https://github.com/opencontainers/distribution-spec/pull/576
  # PR to fix conformance test suite to properly test Content-Range requirement
  # for PATCH requests as specified in the spec. The spec requires Content-Range
  # for PATCH requests to ensure ordered chunk uploads, but the test suite
  # incorrectly omits this requirement. The spec requires:
  # - Content-Range header is required for PATCH requests
  # - Must be inclusive on both ends (e.g. "0-1023")
  # - First chunk must begin with 0
  # - Must match regex ^[0-9]+-[0-9]+$
  def handle(%{method: "PATCH"} = conn, [uuid, "uploads", "blobs" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  def handle(%{method: "GET"} = conn, [uuid, "uploads", "blobs" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  # The closing `PUT` request MUST include the `<digest>` of the whole blob (not the final chunk) as a query parameter.# The closing `PUT` request MUST include the `<digest>` of the whole blob (not the final chunk) as a query parameter.
  def handle(%{method: "PUT"} = conn, [uuid, "uploads", "blobs" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
    registry = conn.private[:oci_registry]
    digest = conn.query_params["digest"]

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

  def handle(%{method: "DELETE"} = conn, [uuid, "uploads", "blobs" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
    registry = conn.private[:oci_registry]

    case Registry.cancel_blob_upload(registry, repo, uuid) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  def handle(%{method: "HEAD"} = conn, [digest, "blobs" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  def handle(%{method: "GET"} = conn, [digest, "blobs" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  def handle(%{method: "DELETE"} = conn, [digest, "blobs" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
    registry = conn.private[:oci_registry]

    case Registry.delete_blob(registry, repo, digest) do
      :ok ->
        send_resp(conn, 202, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  def handle(%{method: "PUT"} = conn, [reference, "manifests" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  def handle(%{method: "GET"} = conn, [reference, "manifests" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  def handle(%{method: "HEAD"} = conn, [reference, "manifests" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
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

  def handle(%{method: "DELETE"} = conn, [reference, "manifests" | rest]) do
    repo = rest |> Enum.reverse() |> Enum.join("/")

    case Registry.delete_manifest(conn.private[:oci_registry], repo, reference) do
      :ok ->
        conn
        |> put_status(202)
        |> send_resp(202, "")

      {:error, oci_error_status} ->
        error_resp(conn, oci_error_status)
    end
  end

  def handle(conn, segments) do
    method = conn.method
    path = segments |> Enum.reverse() |> Enum.join("/")

    # # TODO: should this a 404?
    error_resp(conn, :UNSUPPORTED, "Unsupported [#{method}] #{path}")
  end

  defp pagination(params) do
    n = if params["n"], do: String.to_integer(params["n"]), else: nil
    last = params["last"]

    %Pagination{n: n, last: last}
  end

  defp error_resp(conn, code, details \\ nil) do
    error = OCI.Error.init(code, details)
    body = %{errors: [error]} |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.http_status, body)
    |> halt()
  end

  defp validate_repo_name(conn, rest) do
    repo = rest |> Enum.reverse() |> Enum.join("/")
    registry = conn.private[:oci_registry]

    case Registry.validate_name(registry, repo) do
      :ok ->
        {:ok, repo}

      err ->
        err
    end
  end
end
