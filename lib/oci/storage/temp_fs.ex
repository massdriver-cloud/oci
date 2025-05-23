defmodule OCI.Storage.TempFS do
  @behaviour OCI.StorageAdapter

  def start_link(opts), do: {:ok, opts[:root] || ".oci_tmp"}

  defp repo_path(root, repo), do: Path.join([root, repo])
  defp blob_path(root, repo, digest), do: Path.join([repo_path(root, repo), "blobs", digest])

  defp manifest_path(root, repo, digest),
    do: Path.join([repo_path(root, repo), "manifests", digest])

  defp tag_path(root, repo), do: Path.join([repo_path(root, repo), "tags.json"])

  def init_repo(_repo), do: :ok

  def blob_exists?(repo, digest) do
    # Check global blobs directory for content-addressable storage
    File.exists?(Path.join([root(), "_blobs", digest])) or
      File.exists?(blob_path(root(), repo, digest))
  end

  def get_blob(repo, digest) do
    # Try global blobs directory first
    global_path = Path.join([root(), "_blobs", digest])
    repo_path = blob_path(root(), repo, digest)

    case File.read(global_path) do
      {:ok, content} ->
        {:ok, content}

      _ ->
        case File.read(repo_path) do
          {:ok, content} -> {:ok, content}
          _ -> :error
        end
    end
  end

  def put_blob(_repo, digest, content) do
    # Store in global blobs directory for content-addressable storage
    path = Path.join([root(), "_blobs", digest])
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
          # Store in global blobs directory for content-addressable storage
          path = Path.join([root(), "_blobs", digest])
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)
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
    # First try to resolve as a tag
    case read_tags(repo) do
      {:ok, tags} ->
        digest = Map.get(tags, reference) || reference

        case File.read(manifest_path(root(), repo, digest)) do
          {:ok, content} -> {:ok, content, "application/vnd.oci.image.manifest.v1+json"}
          _ -> :error
        end

      _ ->
        # No tags file, try direct digest lookup
        case File.read(manifest_path(root(), repo, reference)) do
          {:ok, content} -> {:ok, content, "application/vnd.oci.image.manifest.v1+json"}
          _ -> :error
        end
    end
  end

  def put_manifest(repo, reference, content, _media_type) do
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    path = manifest_path(root(), repo, digest)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    # Only update tags if reference is not a digest (i.e., it's a tag name)
    unless reference =~ ~r/^sha256:/, do: update_tag(repo, reference, digest)
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

    case File.ls(root) do
      {:ok, dirs} ->
        repos =
          dirs
          |> Enum.filter(fn d ->
            # Filter out internal directories
            not String.starts_with?(d, ".") and
              not String.starts_with?(d, "_") and
              File.dir?(Path.join(root, d))
          end)
          |> Enum.flat_map(fn namespace_dir ->
            namespace_path = Path.join(root, namespace_dir)

            case File.ls(namespace_path) do
              {:ok, names} ->
                names
                |> Enum.filter(fn name ->
                  File.dir?(Path.join(namespace_path, name)) and
                    not String.starts_with?(name, ".") and
                    not String.starts_with?(name, "_")
                end)
                |> Enum.map(fn name -> "#{namespace_dir}/#{name}" end)

              _ ->
                []
            end
          end)

        {:ok, repos}

      _ ->
        {:ok, []}
    end
  end

  def delete_blob(repo, digest) do
    # Try to delete from both global and repo-specific paths
    global_path = Path.join([root(), "_blobs", digest])
    repo_path = blob_path(root(), repo, digest)

    File.rm(global_path)
    File.rm(repo_path)
    :ok
  end

  def delete_manifest(repo, reference) do
    case read_tags(repo) do
      {:ok, tags} ->
        case Map.get(tags, reference) do
          digest when is_binary(digest) ->
            case File.rm(manifest_path(root(), repo, digest)) do
              :ok ->
                updated = Map.delete(tags, reference)
                File.write!(tag_path(root(), repo), Jason.encode!(updated))
                :ok

              _ ->
                :error
            end

          _ ->
            # Try to delete by reference directly (if it's a digest)
            case File.rm(manifest_path(root(), repo, reference)) do
              :ok -> :ok
              _ -> :error
            end
        end

      _ ->
        :error
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

  defp update_tag(repo, tag, digest) do
    tags =
      case read_tags(repo) do
        {:ok, t} -> t
        _ -> %{}
      end

    updated = Map.put(tags, tag, digest)
    tag_file = tag_path(root(), repo)
    File.mkdir_p!(Path.dirname(tag_file))
    File.write!(tag_file, Jason.encode!(updated))
  end
end
