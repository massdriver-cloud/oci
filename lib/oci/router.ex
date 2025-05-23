defmodule OCI.Router do
  use Plug.Router

  import Plug.Conn

  # Initialize with chosen adapters (defaults to Memory storage and NoAuth)
  def init(opts) do
    adapter =
      opts[:adapter] || Application.get_env(:oci, :storage_adapter, OCI.StorageAdapter.Memory)

    auth = opts[:auth] || Application.get_env(:oci, :auth_adapter, OCI.Auth.NoAuth)
    # Ensure storage agent is started (especially for memory adapter)
    if function_exported?(adapter, :start_link, 1) do
      {:ok, _} = adapter.start_link([])
    end

    %{adapter: adapter, auth: auth}
  end

  def call(conn, opts) do
    # Pass adapter and auth modules via assigns for access in routes
    conn = assign(conn, :storage, opts[:adapter])
    conn = assign(conn, :auth, opts[:auth])
    # proceed with Plug.Router's call (will match routes)
    super(conn, opts)
  end

  plug(:match)
  plug(:dispatch)

  # Utility: send JSON error response with OCI spec error format
  defp send_error(conn, http_status, code) do
    # Map of error codes to default messages (as per OCI spec)
    msg =
      case code do
        "BLOB_UNKNOWN" -> "blob unknown to registry"
        "BLOB_UPLOAD_UNKNOWN" -> "blob upload unknown to registry"
        "BLOB_UPLOAD_INVALID" -> "blob upload invalid"
        "DIGEST_INVALID" -> "provided digest did not match uploaded content"
        "MANIFEST_UNKNOWN" -> "manifest unknown"
        "MANIFEST_INVALID" -> "manifest invalid"
        "NAME_UNKNOWN" -> "repository name not known to registry"
        "UNAUTHORIZED" -> "authentication required"
        "DENIED" -> "access to resource denied"
        "UNSUPPORTED" -> "the operation is unsupported"
        _ -> "unknown error"
      end

    # Build error response body
    error_body =
      %{"errors" => [%{"code" => code, "message" => msg, "detail" => %{}}]}
      |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(http_status, error_body)
    |> halt()
  end

  # Base endpoint: check registry availability (and auth)
  get "/v2/" do
    # Authentication: any request can be authorized/denied based on adapter
    case conn.assigns.auth.authenticate(conn, nil, :base) do
      # Docker spec says an empty 200 OK indicates V2 is supported
      :ok ->
        send_resp(conn, 200, "")

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Catalog listing: list all repositories in the registry
  get "/v2/_catalog" do
    case conn.assigns.auth.authenticate(conn, nil, :list_repos) do
      :ok ->
        {:ok, repos} = conn.assigns.storage.list_repositories()
        body = Jason.encode!(%{"repositories" => repos})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Tags listing: GET /v2/{namespace}/{name}/tags/list
  get "/v2/:namespace/:name/tags/list" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"

    case conn.assigns.auth.authenticate(conn, repo, :list_tags) do
      :ok ->
        case conn.assigns.storage.list_tags(repo) do
          {:ok, tags} ->
            body = Jason.encode!(%{"name" => repo, "tags" => tags})

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, body)

          :error ->
            send_error(conn, 404, "NAME_UNKNOWN")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Blob upload initiation: POST /v2/{namespace}/{name}/blobs/uploads/
  post "/v2/:namespace/:name/blobs/uploads/" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"

    case conn.assigns.auth.authenticate(conn, repo, :push_blob) do
      :ok ->
        # Check query params for mount or digest
        mount_digest = conn.params["mount"]
        mount_from = conn.params["from"]
        digest_param = conn.params["digest"]

        # If ?digest is provided, client attempts a monolithic upload (one-step)
        if digest_param do
          # Monolithic upload: the request body contains the entire blob
          blob_data = read_body_binary(conn)

          actual_digest =
            "sha256:" <> (:crypto.hash(:sha256, blob_data) |> Base.encode16(case: :lower))

          if actual_digest != digest_param do
            send_error(conn, 400, "DIGEST_INVALID")
          else
            conn.assigns.storage.init_repo(repo)
            conn.assigns.storage.put_blob(repo, digest_param, blob_data)
            # Respond 201 Created
            conn
            |> put_resp_header("location", "/v2/#{repo}/blobs/#{digest_param}")
            |> put_resp_header("docker-content-digest", digest_param)
            |> send_resp(201, "")
          end
        else
          # No digest param: maybe a mount request or starting a new upload session
          if mount_digest && mount_from do
            # Attempt to mount an existing blob from another repo
            case conn.assigns.storage.get_blob(mount_from, mount_digest) do
              {:ok, blob} ->
                # Blob exists in source, mount it to target repo
                conn.assigns.storage.init_repo(repo)
                conn.assigns.storage.put_blob(repo, mount_digest, blob)

                conn
                |> put_resp_header("location", "/v2/#{repo}/blobs/#{mount_digest}")
                |> put_resp_header("docker-content-digest", mount_digest)
                |> send_resp(201, "")

              :error ->
                # Source blob not found, proceed with a new upload
                start_upload_session(conn, repo)
            end
          else
            # Normal case: initiate a new upload session
            start_upload_session(conn, repo)
          end
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Blob upload status: GET /v2/{namespace}/{name}/blobs/uploads/{uuid}
  get "/v2/:namespace/:name/blobs/uploads/:uuid" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    upload_id = conn.params["uuid"]

    case conn.assigns.auth.authenticate(conn, repo, :push_blob) do
      :ok ->
        case conn.assigns.storage.upload_chunk(upload_id, <<>>) do
          {:ok, size} ->
            conn
            |> put_resp_header("range", "0-#{size - 1}")
            |> put_resp_header("docker-upload-uuid", upload_id)
            |> send_resp(204, "")

          {:error, _} ->
            send_error(conn, 404, "BLOB_UPLOAD_UNKNOWN")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Blob upload chunk: PATCH /v2/{namespace}/{name}/blobs/uploads/{uuid}
  patch "/v2/:namespace/:name/blobs/uploads/:uuid" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    upload_id = conn.params["uuid"]

    case conn.assigns.auth.authenticate(conn, repo, :push_blob) do
      :ok ->
        chunk = read_body_binary(conn)

        case conn.assigns.storage.upload_chunk(upload_id, chunk) do
          {:ok, total_size} ->
            conn
            |> put_resp_header("location", conn.request_path)
            |> put_resp_header("range", "0-#{total_size - 1}")
            |> put_resp_header("docker-upload-uuid", upload_id)
            |> send_resp(202, "")

          {:error, _} ->
            send_error(conn, 404, "BLOB_UPLOAD_UNKNOWN")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Blob upload finalization: PUT /v2/{namespace}/{name}/blobs/uploads/{uuid}?digest={digest}
  put "/v2/:namespace/:name/blobs/uploads/:uuid" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    upload_id = conn.params["uuid"]

    # Try to get digest from params, or parse from query string
    digest =
      conn.params["digest"] ||
        conn.query_string
        |> URI.decode_query()
        |> Map.get("digest")

    case conn.assigns.auth.authenticate(conn, repo, :push_blob) do
      :ok ->
        if digest do
          case conn.assigns.storage.finalize_blob_upload(upload_id, digest) do
            :ok ->
              conn
              |> put_resp_header("location", "/v2/#{repo}/blobs/#{digest}")
              |> put_resp_header("docker-content-digest", digest)
              |> send_resp(201, "")

            {:error, :digest_mismatch} ->
              send_error(conn, 400, "DIGEST_INVALID")

            {:error, _} ->
              send_error(conn, 404, "BLOB_UPLOAD_UNKNOWN")
          end
        else
          send_error(conn, 400, "DIGEST_INVALID")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Get blob: GET /v2/{namespace}/{name}/blobs/{digest}
  get "/v2/:namespace/:name/blobs/:digest" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    digest = URI.decode(conn.params["digest"])

    case conn.assigns.auth.authenticate(conn, repo, :pull_blob) do
      :ok ->
        case conn.assigns.storage.get_blob(repo, digest) do
          {:ok, data} ->
            conn
            |> put_resp_content_type("application/octet-stream")
            |> put_resp_header("docker-content-digest", digest)
            |> send_resp(200, data)

          :error ->
            send_error(conn, 404, "BLOB_UNKNOWN")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Head blob: HEAD /v2/{namespace}/{name}/blobs/{digest}
  head "/v2/:namespace/:name/blobs/:digest" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    digest = URI.decode(conn.params["digest"])

    case conn.assigns.auth.authenticate(conn, repo, :pull_blob) do
      :ok ->
        case conn.assigns.storage.get_blob(repo, digest) do
          {:ok, _data} ->
            conn
            |> put_resp_content_type("application/octet-stream")
            |> put_resp_header("docker-content-digest", digest)
            |> send_resp(200, "")

          :error ->
            send_error(conn, 404, "BLOB_UNKNOWN")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Delete blob: DELETE /v2/{namespace}/{name}/blobs/{digest}
  delete "/v2/:namespace/:name/blobs/:digest" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    digest = URI.decode(conn.params["digest"])

    case conn.assigns.auth.authenticate(conn, repo, :delete_blob) do
      :ok ->
        case conn.assigns.storage.delete_blob(repo, digest) do
          :ok -> send_resp(conn, 202, "")
          :error -> send_error(conn, 404, "BLOB_UNKNOWN")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Get manifest: GET /v2/{namespace}/{name}/manifests/{reference}
  get "/v2/:namespace/:name/manifests/:reference" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    reference = URI.decode(conn.params["reference"])

    case conn.assigns.auth.authenticate(conn, repo, :pull_manifest) do
      :ok ->
        case conn.assigns.storage.get_manifest(repo, reference) do
          {:ok, content, media_type} ->
            conn
            |> put_resp_header(
              "docker-content-digest",
              "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
            )
            |> put_resp_header(
              "content-type",
              media_type || "application/vnd.oci.image.manifest.v1+json"
            )
            |> send_resp(200, content)

          :error ->
            send_error(conn, 404, "MANIFEST_UNKNOWN")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Head manifest: HEAD /v2/{namespace}/{name}/manifests/{reference}
  head "/v2/:namespace/:name/manifests/:reference" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    reference = URI.decode(conn.params["reference"])

    case conn.assigns.auth.authenticate(conn, repo, :pull_manifest) do
      :ok ->
        case conn.assigns.storage.get_manifest(repo, reference) do
          {:ok, content, _media_type} ->
            conn
            |> put_resp_header(
              "docker-content-digest",
              "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
            )
            |> send_resp(200, "")

          :error ->
            send_error(conn, 404, "MANIFEST_UNKNOWN")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Put manifest: PUT /v2/{namespace}/{name}/manifests/{reference}
  put "/v2/:namespace/:name/manifests/:reference" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    reference = URI.decode(conn.params["reference"])

    case conn.assigns.auth.authenticate(conn, repo, :push_manifest) do
      :ok ->
        content_type = get_req_header(conn, "content-type") |> List.first()
        manifest = read_body_binary(conn)

        case conn.assigns.storage.put_manifest(repo, reference, manifest, content_type) do
          :ok ->
            conn
            |> put_resp_header(
              "docker-content-digest",
              "sha256:#{:crypto.hash(:sha256, manifest) |> Base.encode16(case: :lower)}"
            )
            |> send_resp(201, "")

          {:error, _} ->
            send_error(conn, 400, "MANIFEST_INVALID")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Delete manifest: DELETE /v2/{namespace}/{name}/manifests/{reference}
  delete "/v2/:namespace/:name/manifests/:reference" do
    repo = "#{conn.params["namespace"]}/#{conn.params["name"]}"
    reference = URI.decode(conn.params["reference"])

    case conn.assigns.auth.authenticate(conn, repo, :delete_manifest) do
      :ok ->
        case conn.assigns.storage.delete_manifest(repo, reference) do
          :ok -> send_resp(conn, 202, "")
          :error -> send_error(conn, 404, "MANIFEST_UNKNOWN")
        end

      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="OCIRegistry"))
        |> send_error(401, "UNAUTHORIZED")

      {:error, :denied} ->
        send_error(conn, 403, "DENIED")
    end
  end

  # Fallback for any unmatched routes – return 404 in OCI error format
  match _ do
    send_error(conn, 404, "NAME_UNKNOWN")
  end

  ### Internal helper functions ###

  # Start a new blob upload session and send back 202 Accepted with location
  defp start_upload_session(conn, repo) do
    {:ok, upload_id} = conn.assigns.storage.initiate_blob_upload(repo)
    location = "/v2/#{repo}/blobs/uploads/#{upload_id}"

    conn
    |> put_resp_header("location", location)
    |> put_resp_header("range", "0-0")
    |> put_resp_header("docker-upload-uuid", upload_id)
    |> send_resp(202, "")
  end

  # Read entire request body as binary (handles chunked body in testing or live environment)
  defp read_body_binary(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    body
  end
end
