defmodule OCI.Storage.TempFS do
  @behaviour OCI.StorageAdapter

  def start_link(opts), do: {:ok, opts[:root] || ".oci_tmp"}

  defp repo_path(root, repo), do: Path.join([root, repo])
  defp blob_path(root, repo, digest), do: Path.join([repo_path(root, repo), "blobs", digest])

  defp manifest_path(root, repo, digest),
    do: Path.join([repo_path(root, repo), "manifests", digest])

  defp tag_path(root, repo), do: Path.join([repo_path(root, repo), "tags.json"])

  def init_repo(_repo), do: :ok

  def blob_exists?(repo, digest), do: File.exists?(blob_path(root(), repo, digest))

  def get_blob(repo, digest) do
    path = blob_path(root(), repo, digest)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      _ -> :error
    end
  end

  def put_blob(repo, digest, content) do
    path = blob_path(root(), repo, digest)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    :ok
  end

  def initiate_blob_upload(_repo) do
    id = UUID.uuid4()
    tmp = upload_path(id)
    File.mkdir_p!(Path.dirname(tmp))
    File.write!(tmp, "")
    {:ok, id}
  end

  def upload_chunk(upload_id, chunk) do
    tmp = upload_path(upload_id)
    {:ok, old} = File.read(tmp)
    File.write!(tmp, old <> chunk)
    {:ok, byte_size(old) + byte_size(chunk)}
  end

  def finalize_blob_upload(upload_id, digest) do
    tmp = upload_path(upload_id)

    case File.read(tmp) do
      {:ok, content} ->
        actual = "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

        if digest == actual do
          put_blob("_shared", digest, content)
          File.rm(tmp)
          :ok
        else
          {:error, :digest_mismatch}
        end

      _ ->
        {:error, :upload_not_found}
    end
  end

  def get_manifest(repo, reference) do
    with {:ok, tags} <- read_tags(repo),
         digest when is_binary(digest) <- Map.get(tags, reference),
         {:ok, content} <- File.read(manifest_path(root(), repo, digest)) do
      {:ok, content, "application/vnd.oci.image.manifest.v1+json"}
    else
      _ -> :error
    end
  end

  def put_manifest(repo, reference, content, _media_type) do
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    path = manifest_path(root(), repo, digest)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    tags =
      case read_tags(repo) do
        {:ok, t} -> t
        _ -> %{}
      end

    updated = Map.put(tags, reference, digest)
    File.write!(tag_path(root(), repo), Jason.encode!(updated))
    :ok
  end

  def list_tags(repo) do
    case read_tags(repo) do
      {:ok, tags} -> {:ok, Map.keys(tags)}
      _ -> :error
    end
  end

  def list_repositories() do
    root = root()
    {:ok, dirs} = File.ls(root)
    {:ok, Enum.filter(dirs, fn d -> File.dir?(Path.join(root, d)) end)}
  end

  def delete_blob(repo, digest) do
    File.rm(blob_path(root(), repo, digest))
    :ok
  end

  def delete_manifest(repo, reference) do
    with {:ok, tags} <- read_tags(repo),
         digest <- Map.get(tags, reference),
         :ok <- File.rm(manifest_path(root(), repo, digest)) do
      updated = Map.delete(tags, reference)
      File.write!(tag_path(root(), repo), Jason.encode!(updated))
      :ok
    else
      _ -> :error
    end
  end

  defp upload_path(id), do: Path.join([root(), ".uploads", id])

  defp read_tags(repo) do
    case File.read(tag_path(root(), repo)) do
      {:ok, json} -> Jason.decode(json)
      _ -> {:ok, %{}}
    end
  end

  defp root(), do: Process.get(:oci_tempfs_root, ".oci_tmp")
end
