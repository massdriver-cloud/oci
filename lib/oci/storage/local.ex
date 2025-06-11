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
  def blob_exists?(storage, repo, digest, _ctx) do
    path = digest_path(storage, repo, digest)

    File.exists?(path)
  end

  @impl true
  def cancel_blob_upload(storage, repo, uuid, ctx) do
    upload_dir = upload_dir(storage, repo, uuid)

    if upload_exists?(storage, repo, uuid, ctx) do
      File.rm_rf!(upload_dir)
      :ok
    else
      {:error, :BLOB_UPLOAD_UNKNOWN}
    end
  end

  @impl true
  def complete_blob_upload(storage, repo, uuid, digest, _ctx) do
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
  end

  @impl true
  def delete_blob(storage, repo, digest, _ctx) do
    path = digest_path(storage, repo, digest)

    if File.exists?(path) do
      File.rm!(path)
      :ok
    else
      {:error, :BLOB_UNKNOWN}
    end
  end

  @impl true
  def delete_manifest(storage, repo, digest, _ctx) do
    manifest_path = digest_path(storage, repo, digest)

    if File.exists?(manifest_path) do
      File.rm!(manifest_path)
      :ok
    else
      {:error, :MANIFEST_UNKNOWN}
    end
  end

  @impl true
  def get_blob(storage, repo, digest, _ctx) do
    path = digest_path(storage, repo, digest)

    if File.exists?(path) do
      {:ok, File.read!(path)}
    else
      {:error, :BLOB_UNKNOWN}
    end
  end

  @impl true
  def get_manifest(storage, repo, "sha256:" <> _digest = reference, _ctx) do
    path = digest_path(storage, repo, reference)

    case File.read(path) do
      {:ok, manifest} ->
        {:ok, manifest, @manifest_v1_content_type}

      _ ->
        {:error, :MANIFEST_UNKNOWN, "Reference `#{reference}` not found for repo #{repo}"}
    end
  end

  def get_manifest(storage, repo, tag, ctx) do
    case File.read(tag_path(storage, repo, tag)) do
      {:ok, digest} ->
        get_manifest(storage, repo, digest, ctx)

      _ ->
        {:error, :MANIFEST_UNKNOWN, "Reference `#{tag}` not found for repo #{repo}"}
    end
  end

  @impl true
  def get_blob_upload_offset(storage, repo, uuid, _ctx) do
    upload_dir = upload_dir(storage, repo, uuid)

    data = combine_chunks(upload_dir)
    {:ok, byte_size(data)}
  end

  @impl true
  def get_blob_upload_status(storage, repo, uuid, ctx) do
    if upload_exists?(storage, repo, uuid, ctx) do
      upload_dir = upload_dir(storage, repo, uuid)
      data = combine_chunks(upload_dir)
      range = OCI.Registry.calculate_range(data, 0)
      {:ok, range}
    else
      {:error, :BLOB_UPLOAD_UNKNOWN}
    end
  end

  @impl true
  def manifest_exists?(storage, repo, "sha256:" <> _digest = reference, _ctx) do
    path = digest_path(storage, repo, reference)

    File.exists?(path)
  end

  def manifest_exists?(storage, repo, tag, ctx) do
    tag_path = tag_path(storage, repo, tag)

    # Read the digest from the tag file
    case File.read(tag_path) do
      {:ok, digest} ->
        manifest_exists?(storage, repo, digest, ctx)

      _ ->
        false
    end
  end

  @impl true
  def init(opts) do
    path = Map.fetch!(opts, :path)
    {:ok, %__MODULE__{path: path}}
  end

  @impl true
  def initiate_blob_upload(storage, repo, _ctx) do
    # Create upload directory with UUID
    uuid = UUID.uuid4()
    uploads_dir = uploads_dir(storage, repo)
    :ok = File.mkdir_p!(uploads_dir)

    upload_dir = upload_dir(storage, repo, uuid)
    File.mkdir_p!(upload_dir)

    {:ok, uuid}
  end

  @impl true
  def list_tags(storage, repo, pagination, _ctx) do
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
  def mount_blob(storage, repo, digest, from_repo, _ctx) do
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
  def store_manifest(storage, repo, reference, manifest, manifest_digest, ctx) do
    blobs = [manifest["config"]["digest"]] ++ Enum.map(manifest["layers"], & &1["digest"])

    if Enum.any?(blobs, fn digest ->
         !blob_exists?(storage, repo, digest, ctx)
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
  def repo_exists?(storage, repo, _ctx) do
    File.dir?(repo_dir(storage, repo))
  end

  @impl true
  def upload_blob_chunk(storage, repo, uuid, chunk, _chunk_range, _ctx) do
    upload_dir = upload_dir(storage, repo, uuid)
    index = File.ls!(upload_dir) |> length()

    File.write!("#{upload_dir}/chunk.#{index}", chunk)

    total_range =
      upload_dir
      |> combine_chunks()
      |> OCI.Registry.calculate_range(0)

    {:ok, total_range}
  end

  @impl true
  def upload_exists?(storage, repo, uuid, _ctx) do
    dir = upload_dir(storage, repo, uuid)

    File.exists?(dir)
  end

  # Private Functions (sorted alphabetically)
  defp blob_path(storage, repo, digest) do
    Path.join([blobs_dir(storage, repo), digest])
  end

  defp blobs_dir(storage, repo) do
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

  defp digest_path(storage, repo, digest) do
    Path.join([blobs_dir(storage, repo), digest])
  end

  defp limit(repos, nil), do: repos
  defp limit(repos, n), do: Enum.take(repos, n)

  defp manifests_dir(storage, repo) do
    Path.join([repo_dir(storage, repo), "manifests"])
  end

  defp repo_dir(storage, repo) do
    Path.join([storage.path, repo])
  end

  defp tag_path(storage, repo, tag) do
    Path.join([tags_dir(storage, repo), tag])
  end

  defp tags_dir(storage, repo) do
    Path.join([repo_dir(storage, repo), "manifest", "tags"])
  end

  defp upload_dir(storage, repo, uuid) do
    Path.join([uploads_dir(storage, repo), uuid])
  end

  defp uploads_dir(storage, repo) do
    Path.join([repo_dir(storage, repo), "uploads"])
  end
end
