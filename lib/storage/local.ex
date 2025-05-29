# credo:disable-for-this-file
defmodule OCI.Storage.Local do
  @moduledoc """
  Local storage adapter for OCI.
  """

  @behaviour OCI.Storage.Adapter

  defstruct [:path]

  @type t :: %__MODULE__{
          path: String.t()
        }

  @doc """
  Initializes a new local storage adapter instance with the given configuration.
  """
  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    %__MODULE__{path: path}
  end

  @impl true
  def repo_exists?(%__MODULE__{} = storage, repo) do
    File.dir?(repo_dir(storage, repo))
  end

  @impl true
  def initiate_blob_upload(%__MODULE__{} = storage, repo) do
    # Create upload directory with UUID
    uuid = UUID.uuid4()
    upload_dir = uploads_dir(storage, repo)
    :ok = File.mkdir_p!(upload_dir)

    upload_path = upload_path(storage, repo, uuid)
    File.touch!(upload_path)

    {:ok, uuid}
  end

  @impl true
  def upload_chunk(%__MODULE__{} = _registry, _repo, _uuid, _chunk, 0),
    do: {:error, :BLOB_UPLOAD_INVALID}

  def upload_chunk(%__MODULE__{} = storage, repo, uuid, chunk, _content_length) do
    case upload_exists?(storage, repo, uuid) do
      {:ok, _previous_size} ->
        upload_path = upload_path(storage, repo, uuid)
        # append the chunk to the upload path
        File.write!(upload_path, chunk, [:append])
        upload_size = File.stat!(upload_path).size

        # return the range that was just uploaded
        {:ok, "0-#{upload_size - 1}"}

      err ->
        err
    end
  end

  @impl true
  def get_upload_status(%__MODULE__{} = storage, repo, uuid) do
    case upload_exists?(storage, repo, uuid) do
      {:ok, upload_size} ->
        {:ok, "0-#{upload_size - 1}"}

      err ->
        err
    end
  end

  @impl true
  def complete_blob_upload(%__MODULE__{} = storage, repo, uuid, digest) do
    case upload_exists?(storage, repo, uuid) do
      {:ok, _} ->
        blob_path = blobs_dir(storage, repo)
        File.mkdir_p!(blob_path)

        upload_path = upload_path(storage, repo, uuid)
        digest_path = digest_path(storage, repo, digest)

        with :ok <- OCI.Registry.verify_digest(File.read!(upload_path), digest),
             :ok <- File.rename(upload_path, digest_path) do
          :ok
        else
          {:error, :DIGEST_INVALID} -> {:error, :DIGEST_INVALID}
          _ -> {:error, :BLOB_UPLOAD_UNKNOWN}
        end

      err ->
        err
    end
  end

  @impl true
  def cancel_blob_upload(%__MODULE__{} = storage, repo, uuid) do
    upload_path = upload_path(storage, repo, uuid)

    case upload_exists?(storage, repo, uuid) do
      {:ok, _} ->
        File.rm_rf!(upload_path)
        :ok

      err ->
        err
    end
  end

  @impl true
  def blob_exists?(%__MODULE__{} = storage, repo, digest) do
    path = digest_path(storage, repo, digest)

    if File.exists?(path) do
      {:ok, File.stat!(path).size}
    else
      {:error, :BLOB_UNKNOWN}
    end
  end

  def upload_exists?(%__MODULE__{} = storage, repo, uuid) do
    path = upload_path(storage, repo, uuid)

    case File.exists?(path) do
      true -> {:ok, File.stat!(path).size}
      false -> {:error, :BLOB_UPLOAD_UNKNOWN}
    end
  end

  @impl true
  def get_blob(%__MODULE__{} = storage, repo, digest) do
    path = digest_path(storage, repo, digest)

    if File.exists?(path) do
      {:ok, File.read!(path)}
    else
      {:error, :BLOB_UNKNOWN}
    end
  end

  @impl true
  def delete_blob(%__MODULE__{} = storage, repo, digest) do
    path = digest_path(storage, repo, digest)

    if File.exists?(path) do
      File.rm!(path)
      :ok
    else
      {:error, :BLOB_UNKNOWN}
    end
  end

  @impl true
  def put_manifest(%__MODULE__{} = storage, repo, reference, manifest_json, _content_type) do
    # Validate referenced blobs exist
    case Jason.decode(manifest_json) do
      {:ok, manifest} ->
        blobs = [manifest["config"]["digest"]] ++ Enum.map(manifest["layers"], & &1["digest"])

        if Enum.any?(blobs, fn digest ->
             match?({:error, _}, blob_exists?(storage, repo, digest))
           end) do
          {:error, :MANIFEST_BLOB_UNKNOWN}
        else
          # Calculate digest
          digest =
            "sha256:" <> OCI.Registry.sha256(manifest_json)

          # Store manifest by digest
          :ok = File.mkdir_p!(manifests_dir(storage, repo))
          File.write!(digest_path(storage, repo, digest), manifest_json)

          # If reference is a tag, create a tag reference
          if !String.starts_with?(reference, "sha256:") do
            :ok = File.mkdir_p!(tags_dir(storage, repo))
            File.write!(tag_path(storage, repo, reference), digest)
          end

          {:ok, digest}
        end

      _ ->
        {:error, :MANIFEST_INVALID}
    end
  end

  @impl true
  def get_manifest(%__MODULE__{} = storage, repo, reference) do
    manifest_path =
      if String.starts_with?(reference, "sha256:") do
        digest_path(storage, repo, reference)
      else
        # For tags, read the digest from the tag file and then read the manifest
        if File.exists?(tag_path(storage, repo, reference)) do
          digest = File.read!(tag_path(storage, repo, reference))
          digest_path(storage, repo, digest)
        else
          nil
        end
      end

    if manifest_path && File.exists?(manifest_path) do
      manifest_json = File.read!(manifest_path)

      digest =
        "sha256:" <> OCI.Registry.sha256(manifest_json)

      # If reference is a digest, verify it matches
      if String.starts_with?(reference, "sha256:") and reference != digest do
        {:error, :MANIFEST_UNKNOWN}
      else
        {:ok, manifest_json, "application/vnd.oci.image.manifest.v1+json", digest}
      end
    else
      {:error, :MANIFEST_UNKNOWN}
    end
  end

  @impl true
  def head_manifest(%__MODULE__{} = storage, repo, reference) do
    manifest_path =
      if String.starts_with?(reference, "sha256:") do
        digest_path(storage, repo, reference)
      else
        # For tags, read the digest from the tag file and then read the manifest
        if File.exists?(tag_path(storage, repo, reference)) do
          digest = File.read!(tag_path(storage, repo, reference))
          digest_path(storage, repo, digest)
        else
          nil
        end
      end

    if manifest_path && File.exists?(manifest_path) do
      manifest_json = File.read!(manifest_path)

      digest =
        "sha256:" <> OCI.Registry.sha256(manifest_json)

      # If reference is a digest, verify it matches
      if String.starts_with?(reference, "sha256:") and reference != digest do
        {:error, :MANIFEST_UNKNOWN}
      else
        {:ok, "application/vnd.oci.image.manifest.v1+json", digest, String.length(manifest_json)}
      end
    else
      {:error, :MANIFEST_UNKNOWN}
    end
  end

  @impl true
  def delete_manifest(%__MODULE__{} = storage, repo, digest) do
    manifest_path = digest_path(storage, repo, digest)

    if File.exists?(manifest_path) do
      File.rm!(manifest_path)
      :ok
    else
      {:error, :MANIFEST_UNKNOWN}
    end
  end

  @impl true
  def list_tags(%__MODULE__{} = storage, repo, pagination) do
    if File.dir?(tags_dir(storage, repo)) do
      tags =
        tags_dir(storage, repo)
        |> File.ls!()
        |> Enum.sort()

      paginated_tags =
        tags
        |> cursor(pagination.last)
        |> limit(pagination.n)

      {:ok, paginated_tags}
    else
      {:error, :NAME_UNKNOWN}
    end
  end

  @impl true
  def mount_blob(%__MODULE__{} = storage, repo, digest, from_repo) do
    source_path = blob_path(storage, from_repo, digest)
    target_path = blob_path(storage, repo, digest)

    if File.exists?(source_path) do
      # Create target directory if it doesn't exist
      File.mkdir_p!(Path.dirname(target_path))
      # Copy the blob file
      File.cp!(source_path, target_path)
      :ok
    else
      {:error, :BLOB_UNKNOWN}
    end
  end

  defp repo_dir(%__MODULE__{} = storage, repo) do
    Path.join([storage.path, repo])
  end

  defp uploads_dir(%__MODULE__{} = storage, repo) do
    Path.join([repo_dir(storage, repo), "uploads"])
  end

  defp upload_path(%__MODULE__{} = storage, repo, uuid) do
    Path.join([uploads_dir(storage, repo), uuid])
  end

  defp blobs_dir(%__MODULE__{} = storage, repo) do
    Path.join([repo_dir(storage, repo), "blobs"])
  end

  defp blob_path(%__MODULE__{} = storage, repo, digest) do
    Path.join([blobs_dir(storage, repo), digest])
  end

  defp digest_path(%__MODULE__{} = storage, repo, digest) do
    Path.join([blobs_dir(storage, repo), digest])
  end

  defp manifests_dir(%__MODULE__{} = storage, repo) do
    Path.join([repo_dir(storage, repo), "manifests"])
  end

  defp tags_dir(%__MODULE__{} = storage, repo) do
    Path.join([repo_dir(storage, repo), "manifest", "tags"])
  end

  defp tag_path(%__MODULE__{} = storage, repo, tag) do
    Path.join([tags_dir(storage, repo), tag])
  end

  defp cursor(repos, nil), do: repos

  defp cursor(repos, cursor) do
    repos
    |> Enum.drop_while(fn repo -> repo != cursor end)
    |> Enum.drop(1)
  end

  defp limit(repos, nil), do: repos
  defp limit(repos, n), do: Enum.take(repos, n)
end
