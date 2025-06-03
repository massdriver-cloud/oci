# credo:disable-for-this-file
defmodule OCI.Storage.Local do
  @moduledoc """
  Local storage adapter for OCI.

  File system structure:
  ```
  <root_path>/
  ├── <repo>/
  │   ├── blobs/
  │   │   └── sha256:<digest>  # Stored blobs
  │   ├── uploads/
  │   │   └── <uuid>/          # Temporary upload directory
  │   │       └── chunk.*      # Chunked upload files
  │   ├── manifests/           # Manifest storage
  │   │   └── sha256:<digest>  # Stored manifests
  │   └── manifest/
  │       └── tags/            # Tag references
  │           └── <tag>        # Tag to digest mapping
  ```
  The local storage adapter implements the OCI distribution spec by storing:
  - Blobs in the `blobs/` directory, named by their digest
  - Manifests in the `manifests/` directory, named by their digest
  - Tag references in `manifest/tags/`, mapping tags to manifest digests
  - Temporary uploads in `uploads/<uuid>/` during chunked uploads
  """

  @behaviour OCI.Storage.Adapter
  @manifest_v1_content_type "application/vnd.oci.image.manifest.v1+json"

  use TypedStruct

  typedstruct do
    field :path, String.t(), enforce: true
  end

  # Public Functions (sorted alphabetically)
  @impl true
  def blob_exists?(%__MODULE__{} = storage, repo, digest) do
    path = digest_path(storage, repo, digest)

    if File.exists?(path) do
      {:ok, File.stat!(path).size}
    else
      {:error, :BLOB_UNKNOWN}
    end
  end

  @impl true
  def cancel_blob_upload(%__MODULE__{} = storage, repo, uuid) do
    upload_dir = upload_dir(storage, repo, uuid)

    case upload_exists?(storage, repo, uuid) do
      :ok ->
        File.rm_rf!(upload_dir)
        :ok

      err ->
        err
    end
  end

  @impl true
  def complete_blob_upload(%__MODULE__{} = storage, repo, uuid, digest) do
    case upload_exists?(storage, repo, uuid) do
      :ok ->
        blob_path = blobs_dir(storage, repo)
        File.mkdir_p!(blob_path)

        upload_dir = upload_dir(storage, repo, uuid)
        digest_path = digest_path(storage, repo, digest)

        data = combine_chunks(upload_dir)

        with :ok <- OCI.Registry.verify_digest(data, digest),
             :ok <- File.write!(digest_path, data) do
          :ok
        else
          {:error, :DIGEST_INVALID} ->
            {:error, :DIGEST_INVALID}

          _ ->
            {:error, :BLOB_UPLOAD_UNKNOWN}
        end

      err ->
        err
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
  def get_blob(%__MODULE__{} = storage, repo, digest) do
    path = digest_path(storage, repo, digest)

    if File.exists?(path) do
      {:ok, File.read!(path)}
    else
      {:error, :BLOB_UNKNOWN}
    end
  end

  @impl true
  def get_manifest(%__MODULE__{} = storage, repo, "sha256:" <> _digest = reference) do
    path = digest_path(storage, repo, reference)

    case File.read(path) do
      {:ok, manifest} ->
        {:ok, manifest, @manifest_v1_content_type}

      _ ->
        {:error, :MANIFEST_UNKNOWN, "Reference `#{reference}` not found for repo #{repo}"}
    end
  end

  def get_manifest(%__MODULE__{} = storage, repo, tag) do
    case File.read(tag_path(storage, repo, tag)) do
      {:ok, digest} ->
        get_manifest(storage, repo, digest)

      _ ->
        {:error, :MANIFEST_UNKNOWN, "Reference `#{tag}` not found for repo #{repo}"}
    end
  end

  @impl true
  def get_blob_upload_offset(%__MODULE__{} = storage, repo, uuid) do
    upload_dir = upload_dir(storage, repo, uuid)

    data = combine_chunks(upload_dir)
    {:ok, byte_size(data)}
  end

  @impl true
  def get_blob_upload_status(%__MODULE__{} = storage, repo, uuid) do
    case upload_exists?(storage, repo, uuid) do
      :ok ->
        upload_dir = upload_dir(storage, repo, uuid)
        data = combine_chunks(upload_dir)
        range = OCI.Registry.calculate_range(data, 0)
        {:ok, range}

      err ->
        err
    end
  end

  @impl true
  def get_manifest_metadata(storage, repo, "sha256:" <> _digest = reference) do
    path = digest_path(storage, repo, reference)

    case File.stat(path) do
      {:ok, stat} ->
        {:ok, @manifest_v1_content_type, stat.size}

      _err ->
        {:error, :MANIFEST_UNKNOWN, "Reference `#{reference}` not found for repo #{repo}"}
    end
  end

  def get_manifest_metadata(storage, repo, tag) do
    tag_path = tag_path(storage, repo, tag)

    # Read the digest from the tag file
    case File.read(tag_path) do
      {:ok, digest} ->
        get_manifest_metadata(storage, repo, digest)

      _ ->
        {:error, :MANIFEST_UNKNOWN, "Reference `#{tag}` not found for repo #{repo}"}
    end
  end

  @impl true
  def init(opts) do
    path = Map.fetch!(opts, :path)
    {:ok, %__MODULE__{path: path}}
  end

  @impl true
  def initiate_blob_upload(%__MODULE__{} = storage, repo) do
    # Create upload directory with UUID
    uuid = UUID.uuid4()
    uploads_dir = uploads_dir(storage, repo)
    :ok = File.mkdir_p!(uploads_dir)

    upload_dir = upload_dir(storage, repo, uuid)
    File.mkdir_p!(upload_dir)

    {:ok, uuid}
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

  @impl true
  def store_manifest(%__MODULE__{} = storage, repo, reference, manifest, manifest_digest) do
    blobs = [manifest["config"]["digest"]] ++ Enum.map(manifest["layers"], & &1["digest"])

    if Enum.any?(blobs, fn digest ->
         match?({:error, _}, blob_exists?(storage, repo, digest))
       end) do
      # TODO; return which blobs are missing.
      # TODO: is this the right error or MANIFEST_INVALID?
      {:error, :MANIFEST_BLOB_UNKNOWN, ""}
    else
      # Store manifest by digest
      manifest_json = Jason.encode!(manifest)

      :ok = File.mkdir_p!(manifests_dir(storage, repo))
      File.write!(digest_path(storage, repo, manifest_digest), manifest_json)

      # If reference is a tag, create a tag reference
      if !String.starts_with?(reference, "sha256:") do
        :ok = File.mkdir_p!(tags_dir(storage, repo))
        File.write!(tag_path(storage, repo, reference), manifest_digest)
      end

      :ok
    end
  end

  @impl true
  def repo_exists?(%__MODULE__{} = storage, repo) do
    File.dir?(repo_dir(storage, repo))
  end

  @impl true
  def upload_blob_chunk(%__MODULE__{} = storage, repo, uuid, chunk, _chunk_range) do
    upload_dir = upload_dir(storage, repo, uuid)
    index = File.ls!(upload_dir) |> length()

    File.write!("#{upload_dir}/chunk.#{index}", chunk)

    total_range =
      upload_dir
      |> combine_chunks()
      |> OCI.Registry.calculate_range(0)

    {:ok, total_range}
  end

  def upload_exists?(%__MODULE__{} = storage, repo, uuid) do
    dir = upload_dir(storage, repo, uuid)

    case File.exists?(dir) do
      true -> :ok
      false -> {:error, :BLOB_UPLOAD_UNKNOWN}
    end
  end

  # Private Functions (sorted alphabetically)
  defp blob_path(%__MODULE__{} = storage, repo, digest) do
    Path.join([blobs_dir(storage, repo), digest])
  end

  defp blobs_dir(%__MODULE__{} = storage, repo) do
    Path.join([repo_dir(storage, repo), "blobs"])
  end

  defp combine_chunks(upload_dir) do
    chunks = File.ls!(upload_dir)

    chunks
    |> Enum.map(fn chunk -> File.read!(Path.join(upload_dir, chunk)) end)
    |> Enum.join()
  end

  defp cursor(repos, nil), do: repos

  defp cursor(repos, cursor) do
    repos
    |> Enum.drop_while(fn repo -> repo != cursor end)
    |> Enum.drop(1)
  end

  defp digest_path(%__MODULE__{} = storage, repo, digest) do
    Path.join([blobs_dir(storage, repo), digest])
  end

  defp limit(repos, nil), do: repos
  defp limit(repos, n), do: Enum.take(repos, n)

  defp manifests_dir(%__MODULE__{} = storage, repo) do
    Path.join([repo_dir(storage, repo), "manifests"])
  end

  defp repo_dir(%__MODULE__{} = storage, repo) do
    Path.join([storage.path, repo])
  end

  defp tag_path(%__MODULE__{} = storage, repo, tag) do
    Path.join([tags_dir(storage, repo), tag])
  end

  defp tags_dir(%__MODULE__{} = storage, repo) do
    Path.join([repo_dir(storage, repo), "manifest", "tags"])
  end

  defp upload_dir(%__MODULE__{} = storage, repo, uuid) do
    Path.join([uploads_dir(storage, repo), uuid])
  end

  defp uploads_dir(%__MODULE__{} = storage, repo) do
    Path.join([repo_dir(storage, repo), "uploads"])
  end
end
