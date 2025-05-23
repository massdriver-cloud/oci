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

  # Tags listing: GET /v2/<name>/tags/list[?n=<max>&last=<last_tag>]
  get "/v2/:repo/tags/list" do
    # decode in case repo contains %2F
    repo = URI.decode(conn.params["repo"] || "")

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

  # Handle all /v2/*path routes
  match "/v2/*path" do
    path = Enum.join(conn.path_info, "/")

    cond do
      # Manifest routes
      String.ends_with?(path, "/manifests/") ->
        case conn.method do
          "GET" -> handle_get_manifest(conn, parse_repo_path(conn.path_info, "manifests"))
          "HEAD" -> handle_get_manifest(conn, parse_repo_path(conn.path_info, "manifests"))
          "PUT" -> handle_put_manifest(conn, parse_repo_path(conn.path_info, "manifests"))
          "DELETE" -> handle_delete_manifest(conn, parse_repo_path(conn.path_info, "manifests"))
          _ -> conn
        end

      # Blob routes
      String.ends_with?(path, "/blobs/") ->
        case conn.method do
          "GET" -> handle_get_blob(conn, parse_repo_path(conn.path_info, "blobs"))
          "HEAD" -> handle_get_blob(conn, parse_repo_path(conn.path_info, "blobs"))
          "DELETE" -> handle_delete_blob(conn, parse_repo_path(conn.path_info, "blobs"))
          _ -> conn
        end

      # Blob upload routes
      String.ends_with?(path, "/blobs/uploads/") ->
        case conn.method do
          "GET" -> handle_get_upload(conn, parse_repo_path(conn.path_info, "blobs"))
          "PATCH" -> handle_patch_upload(conn, parse_repo_path(conn.path_info, "blobs"))
          "PUT" -> handle_put_upload(conn, parse_repo_path(conn.path_info, "blobs"))
          "POST" -> handle_post_upload(conn, parse_repo_path(conn.path_info, "blobs"))
          _ -> conn
        end

      # No matching route
      true ->
        send_error(conn, 404, "UNSUPPORTED")
    end
  end

  # Helper functions for route handlers
  defp handle_get_manifest(conn, {:ok, repo, ["manifests", reference]}) do
    case conn.assigns.auth.authenticate(conn, repo, :pull_manifest) do
      :ok ->
        case conn.assigns.storage.get_manifest(repo, URI.decode(reference || "")) do
          {:ok, content, media_type} ->
            conn =
              put_resp_header(
                conn,
                "Docker-Content-Digest",
                "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
              )

            conn =
              put_resp_content_type(
                conn,
                media_type || "application/vnd.oci.image.manifest.v1+json"
              )

            if conn.method == "HEAD" do
              send_resp(conn, 200, "")
            else
              send_resp(conn, 200, content)
            end

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

  defp handle_get_manifest(conn, _), do: send_error(conn, 404, "MANIFEST_UNKNOWN")

  defp handle_get_blob(conn, {:ok, repo, ["blobs", digest]}) when digest != "uploads" do
    case conn.assigns.auth.authenticate(conn, repo, :pull_blob) do
      :ok ->
        case conn.assigns.storage.get_blob(repo, URI.decode(digest || "")) do
          {:ok, data} ->
            conn = put_resp_content_type(conn, "application/octet-stream")
            conn = put_resp_header(conn, "Docker-Content-Digest", digest)

            if conn.method == "HEAD" do
              send_resp(conn, 200, "")
            else
              send_resp(conn, 200, data)
            end

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

  defp handle_get_blob(conn, _), do: conn

  defp handle_delete_blob(conn, {:ok, repo, ["blobs", digest]}) do
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

  defp handle_delete_blob(conn, _), do: conn

  defp handle_get_upload(conn, {:ok, repo, ["blobs", "uploads"]}) do
    case conn.assigns.auth.authenticate(conn, repo, :push_blob) do
      :ok ->
        upload_id = conn.params["uuid"]

        case conn.assigns.storage.upload_chunk(upload_id, <<>>) do
          {:ok, size} ->
            conn
            |> put_resp_header("Range", "0-#{size - 1}")
            |> put_resp_header("Docker-Upload-UUID", upload_id)
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

  defp handle_get_upload(conn, _), do: conn

  defp handle_patch_upload(conn, {:ok, repo, ["blobs", "uploads"]}) do
    case conn.assigns.auth.authenticate(conn, repo, :push_blob) do
      :ok ->
        upload_id = conn.params["uuid"]
        chunk = read_body_binary(conn)

        case conn.assigns.storage.upload_chunk(upload_id, chunk) do
          {:ok, _size} ->
            conn
            |> put_resp_header("Location", "#{conn.request_path}")
            |> put_resp_header("Docker-Upload-UUID", upload_id)
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

  defp handle_patch_upload(conn, _), do: conn

  defp handle_put_upload(conn, {:ok, repo, ["blobs", "uploads"]}) do
    case conn.assigns.auth.authenticate(conn, repo, :push_blob) do
      :ok ->
        upload_id = conn.params["uuid"]
        digest = conn.params["digest"]

        if digest do
          case conn.assigns.storage.finalize_blob_upload(upload_id, digest) do
            :ok ->
              conn
              |> put_resp_header("Location", "#{conn.script_name}/v2/#{repo}/blobs/#{digest}")
              |> put_resp_header("Docker-Content-Digest", digest)
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

  defp handle_put_upload(conn, _), do: conn

  defp handle_put_manifest(conn, {:ok, repo, ["manifests", reference]}) do
    case conn.assigns.auth.authenticate(conn, repo, :push_manifest) do
      :ok ->
        content_type = get_req_header(conn, "content-type") |> List.first()
        manifest = read_body_binary(conn)

        case conn.assigns.storage.put_manifest(repo, reference, manifest, content_type) do
          :ok ->
            conn
            |> put_resp_header(
              "Docker-Content-Digest",
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

  defp handle_put_manifest(conn, _), do: send_error(conn, 404, "MANIFEST_UNKNOWN")

  defp handle_delete_manifest(conn, {:ok, repo, ["manifests", reference]}) do
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

  defp handle_delete_manifest(conn, _), do: send_error(conn, 404, "MANIFEST_UNKNOWN")

  defp handle_post_upload(conn, {:ok, repo, ["blobs", "uploads"]}) do
    case conn.assigns.auth.authenticate(conn, repo, :push_blob) do
      :ok ->
        # Check query params for mount or digest
        upload_adapter = conn.assigns.storage
        mount_digest = conn.params["mount"]
        mount_from = conn.params["from"]
        digest_param = conn.params["digest"]

        # If ?digest is provided, client attempts a monolithic upload (one-step)
        if digest_param do
          # Monolithic upload: the request body *should* contain the entire blob
          blob_data = read_body_binary(conn)
          # Validate and store blob directly
          actual_digest =
            "sha256:" <> (:crypto.hash(:sha256, blob_data) |> Base.encode16(case: :lower))

          if actual_digest != digest_param do
            send_error(conn, 400, "DIGEST_INVALID")
          else
            upload_adapter.init_repo(repo)
            upload_adapter.put_blob(repo, digest_param, blob_data)
            # Respond 201 Created
            conn
            # location of the blob
            |> put_resp_header("Location", "#{conn.request_path}#{digest_param}")
            |> put_resp_header("Docker-Content-Digest", digest_param)
            |> send_resp(201, "")
          end
        else
          # No digest param: maybe a mount request or starting a new upload session
          if mount_digest && mount_from do
            # Attempt to mount an existing blob from another repo
            case upload_adapter.get_blob(mount_from, mount_digest) do
              {:ok, blob} ->
                # Blob exists in source, mount it to target repo
                upload_adapter.init_repo(repo)
                upload_adapter.put_blob(repo, mount_digest, blob)

                conn
                |> put_resp_header(
                  "Location",
                  "#{conn.script_name}/v2/#{repo}/blobs/#{mount_digest}"
                )
                |> put_resp_header("Docker-Content-Digest", mount_digest)
                |> send_resp(201, "")

              :error ->
                # Source blob not found, proceed with a new upload
                start_upload_session(conn, repo, upload_adapter)
            end
          else
            # Normal case: initiate a new upload session
            start_upload_session(conn, repo, upload_adapter)
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

  defp handle_post_upload(conn, _), do: conn

  # Start a new blob upload session and send back 202 Accepted with location
  defp start_upload_session(conn, repo, adapter) do
    {:ok, upload_id} = adapter.initiate_blob_upload(repo)
    # Location header: points to the upload status endpoint
    # Use conn.script_name (base path) if present (Plug in endpoint scenario), otherwise just build path
    location = "#{conn.script_name}/v2/#{repo}/blobs/uploads/#{upload_id}"

    conn
    |> put_resp_header("Location", location)
    |> put_resp_header("Range", "0-0")
    |> put_resp_header("Docker-Upload-UUID", upload_id)
    |> send_resp(202, "")
  end

  # Utility: parse a path_info list to separate repository name and trailing segments.
  # Looks for a marker (like "manifests", "blobs", etc.) and splits the list at that point.
  def parse_repo_path(path_info, marker) do
    # e.g. path_info = ["v2", "myorg", "myrepo", "manifests", "latest"]
    # marker = "manifests"
    # This should return {:ok, "myorg/myrepo", ["manifests", "latest"]}
    case Enum.split_while(path_info, &(&1 != marker)) do
      {repo_parts, [^marker | _rest] = trailing} when repo_parts != [] and trailing != [] ->
        # drop the "v2" prefix
        repo = repo_parts |> Enum.drop(1) |> Enum.map(&URI.decode/1) |> Enum.join("/")
        {:ok, repo, trailing}

      _ ->
        :error
    end
  end

  ### Internal helper functions ###

  # Read entire request body as binary (handles chunked body in testing or live environment)
  defp read_body_binary(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    body
  end
end
