defmodule OCI.Plug.Handler do
  @moduledoc """
  Handles OCI requests.

  This module is responsible for dispatching OCI requests to the appropriate
  handler function.

  It also validates the repository name and handles pagination.
  """
  import Plug.Conn
  alias OCI.Registry
  alias OCI.Registry.Pagination

  def handle(%{halted: true} = conn), do: conn

  def handle(%{assigns: %{oci_ctx: ctx}} = conn) when ctx.endpoint == :ping do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, "{}")
  end

  def handle(%{assigns: %{oci_ctx: ctx}} = conn) do
    case Registry.validate_repository_name(conn.private[:oci_registry], ctx.repo) do
      {:ok, repo} ->
        registry = conn.private[:oci_registry]

        # Expects a conn as a success or a failure, alternatively return an error
        # to be handled by the default error handler.
        case dispatch(conn, ctx.endpoint, registry, repo, ctx.resource) do
          %Plug.Conn{} = conn ->
            conn

          {:error, oci_error_status} ->
            you_suck_and_are_a_bad_person_messsage = """
            You suck and are a bad person.

            Please return error details for #{oci_error_status} in #{inspect(ctx)}
            """

            error_resp(conn, oci_error_status, you_suck_and_are_a_bad_person_messsage)

          {:error, oci_error_status, details} ->
            error_resp(conn, oci_error_status, details)
        end

      {:error, oci_error_status, details} ->
        error_resp(conn, oci_error_status, details)
    end
  end

  @spec dispatch(
          conn :: Plug.Conn.t(),
          endpoint :: atom(),
          registry :: Registry.t(),
          repo :: String.t(),
          id :: String.t()
        ) :: Plug.Conn.t() | {:error, atom()} | {:error, atom(), String.t()}
  defp dispatch(%{method: "GET"} = conn, :tags_list, registry, repo, _id) do
    with {:ok, tags} <- Registry.list_tags(registry, repo, pagination(conn.query_params)) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{name: repo, tags: tags}))
    end
  end

  # Cross-repo mounting
  defp dispatch(
         %{method: "POST", query_params: %{"mount" => mount, "from" => from}} = conn,
         :blobs_uploads,
         registry,
         repo,
         _id
       ) do
    with {:ok, location} <- Registry.mount_blob(registry, repo, mount, from) do
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
    end
  end

  # Monolithic POST
  defp dispatch(
         %{method: "POST", query_params: %{"digest" => digest}} = conn,
         :blobs_uploads,
         registry,
         repo,
         _id
       ) do
    case Registry.initiate_blob_upload(registry, repo) do
      {:ok, location} ->
        upload_id = location |> String.split("/") |> List.last()
        chunk = conn.assigns[:oci_blob_chunk]

        case Registry.upload_blob_chunk(
               registry,
               repo,
               upload_id,
               chunk,
               nil
             ) do
          {:ok, _, _} ->
            :ok

          # TODO: we are swallowing this error!!! Yikes.
          err ->
            err
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

          err ->
            err
        end

      err ->
        err
    end
  end

  # Initiate a chunked blob upload session
  defp dispatch(%{method: "POST"} = conn, :blobs_uploads, registry, repo, _id) do
    with {:ok, location} <- Registry.initiate_blob_upload(registry, repo) do
      conn
      |> put_resp_header("location", location)
      |> send_resp(202, "")
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
  defp dispatch(%{method: "PATCH"} = conn, :blobs_uploads, registry, repo, uuid) do
    content_range = conn |> get_req_header("content-range") |> List.first()

    case content_range do
      nil ->
        error_resp(
          conn,
          :BLOB_UPLOAD_INVALID,
          "Content-Range header is required for PATCH requests"
        )

      _ ->
        chunk = conn.assigns[:oci_blob_chunk]

        case Registry.upload_blob_chunk(registry, repo, uuid, chunk, content_range) do
          {:ok, location, range} ->
            conn
            |> put_resp_header("location", location)
            |> put_resp_header("range", range)
            |> send_resp(202, "")

          err ->
            err
        end
    end
  end

  defp dispatch(%{method: "GET"} = conn, :blobs_uploads, registry, repo, uuid) do
    with {:ok, location, range} <- Registry.get_blob_upload_status(registry, repo, uuid) do
      conn
      |> put_resp_header("location", location)
      |> put_resp_header("range", range)
      |> send_resp(204, "")
    end
  end

  # The closing `PUT` request MUST include the `<digest>` of the whole blob (not the final chunk) as a query parameter.
  defp dispatch(%{method: "PUT"} = conn, :blobs_uploads, registry, repo, uuid) do
    digest = conn.query_params["digest"]

    # Must have a content-length, it may be 0 depending on if a final chunk is being uploaded or not with the digest.
    with :ok <- maybe_upload_final_chunk(conn, registry, repo, uuid),
         {:ok, location} <- Registry.complete_blob_upload(registry, repo, uuid, digest) do
      conn
      |> put_resp_header("location", location)
      |> send_resp(201, "")
    end
  end

  defp dispatch(%{method: "DELETE"} = conn, :blobs_uploads, registry, repo, uuid) do
    with :ok <- Registry.cancel_blob_upload(registry, repo, uuid) do
      send_resp(conn, 204, "")
    end
  end

  defp dispatch(%{method: "HEAD"} = conn, :blobs, registry, repo, digest) do
    with {:ok, size} <- Registry.blob_exists?(registry, repo, digest) do
      conn
      |> put_resp_header("content-length", "#{size}")
      |> send_resp(200, "")
    end
  end

  defp dispatch(%{method: "GET"} = conn, :blobs, registry, repo, digest) do
    with {:ok, content} <- Registry.get_blob(registry, repo, digest) do
      conn
      |> put_resp_header("content-length", "#{byte_size(content)}")
      |> send_resp(200, content)
    end
  end

  defp dispatch(%{method: "DELETE"} = conn, :blobs, registry, repo, digest) do
    with :ok <- Registry.delete_blob(registry, repo, digest) do
      send_resp(conn, 202, "")
    end
  end

  defp dispatch(%{method: "PUT"} = conn, :manifests, registry, repo, reference) do
    manifest = conn.params
    manifest_digest = conn.assigns[:oci_digest]

    with :ok <- Registry.store_manifest(registry, repo, reference, manifest, manifest_digest) do
      conn
      |> put_resp_header("location", Registry.manifests_reference_path(repo, reference))
      |> send_resp(201, "")
    end
  end

  defp dispatch(%{method: "GET"} = conn, :manifests, registry, repo, reference) do
    with {:ok, manifest, content_type} <- Registry.get_manifest(registry, repo, reference) do
      conn
      |> put_resp_header("content-type", content_type)
      |> send_resp(200, manifest)
    end
  end

  defp dispatch(%{method: "HEAD"} = conn, :manifests, registry, repo, reference) do
    with {:ok, content_type, size} <- Registry.get_manifest_metadata(registry, repo, reference) do
      conn
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("content-length", "#{size}")
      |> send_resp(200, "")
    end
  end

  defp dispatch(%{method: "DELETE"} = conn, :manifests, registry, repo, reference) do
    with :ok <- Registry.delete_manifest(registry, repo, reference) do
      conn
      |> put_status(202)
      |> send_resp(202, "")
    end
  end

  defp dispatch(conn, _endpoint, _registry, _repo, _id) do
    method = conn.method
    path = conn.request_path

    {:error, :UNSUPPORTED, "Unsupported [#{method}] #{path}"}
  end

  defp pagination(params) do
    n = if params["n"], do: String.to_integer(params["n"]), else: nil
    last = params["last"]

    %Pagination{n: n, last: last}
  end

  defp error_resp(conn, code, details) do
    error = OCI.Error.init(code, details)
    body = %{errors: [error]} |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.http_status, body)
  end

  defp maybe_upload_final_chunk(conn, registry, repo, uuid) do
    # The Content-Length header is required, but may be 0 if no final chunk is being uploaded.
    conn
    |> get_req_header("content-length")
    |> List.first()
    |> String.to_integer()
    |> case do
      0 ->
        # No chunk to upload with final PUT
        :ok

      _ ->
        # Final chunk is included, upload it before completing the blob
        case Registry.upload_blob_chunk(
               registry,
               repo,
               uuid,
               conn.assigns[:oci_blob_chunk],
               nil
             ) do
          {:ok, _, _} -> :ok
          {:error, reason} -> {:error, reason}
          {:error, reason, details} -> {:error, reason, details}
        end
    end
  end
end
