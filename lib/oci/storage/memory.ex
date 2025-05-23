defmodule OCI.StorageAdapter.Memory do
  @behaviour OCI.StorageAdapter
  use Agent

  @doc "Starts the memory storage agent (if not already started)."
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{repos: %{}, uploads: %{}} end, name: __MODULE__)
  end

  @doc "Reset the in-memory storage (for tests or fresh start)."
  def reset() do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> Agent.update(__MODULE__, fn _ -> %{repos: %{}, uploads: %{}} end)
    end

    :ok
  end

  def init_repo(repo) do
    Agent.update(__MODULE__, fn state ->
      if Map.has_key?(state.repos, repo) do
        state
      else
        put_in(state, [:repos, repo], %{blobs: %{}, manifests: %{}, tags: %{}})
      end
    end)

    :ok
  end

  def blob_exists?(repo, digest) do
    Agent.get(__MODULE__, fn state ->
      case get_in(state, [:repos, repo, :blobs, digest]) do
        nil -> false
        _ -> true
      end
    end)
  end

  def get_blob(repo, digest) do
    Agent.get(__MODULE__, fn state ->
      case get_in(state, [:repos, repo, :blobs, digest]) do
        nil -> :error
        blob -> {:ok, blob}
      end
    end)
  end

  def put_blob(repo, digest, content) do
    # ensure repo exists
    init_repo(repo)

    Agent.update(__MODULE__, fn state ->
      put_in(state, [:repos, repo, :blobs, digest], content)
    end)

    :ok
  end

  def initiate_blob_upload(repo) do
    init_repo(repo)
    # Generate a unique upload ID (UUID-like random hex string)
    upload_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Agent.update(__MODULE__, fn state ->
      put_in(state, [:uploads, upload_id], %{repo: repo, data: <<>>})
    end)

    {:ok, upload_id}
  end

  def upload_chunk(upload_id, chunk) do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.uploads[upload_id] do
        nil ->
          {{:error, :upload_not_found}, state}

        %{data: data} = _upload_state ->
          new_data = data <> chunk
          new_state = put_in(state, [:uploads, upload_id, :data], new_data)
          {{:ok, byte_size(new_data)}, new_state}
      end
    end)
  end

  def finalize_blob_upload(upload_id, digest) do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.uploads[upload_id] do
        nil ->
          {{:error, :upload_not_found}, state}

        %{repo: repo, data: data} ->
          # Compute actual digest of data to verify
          actual = "sha256:" <> (:crypto.hash(:sha256, data) |> Base.encode16(case: :lower))

          if digest != actual do
            # Digest mismatch – discard upload and return error
            new_state = update_in(state, [:uploads], &Map.delete(&1, upload_id))
            {{:error, :digest_mismatch}, new_state}
          else
            # Store the blob, remove the upload session
            new_state =
              state
              |> put_in([:repos, repo, :blobs, digest], data)
              |> update_in([:uploads], &Map.delete(&1, upload_id))

            {:ok, new_state}
          end
      end
    end)
  end

  def get_manifest(repo, reference) do
    Agent.get(__MODULE__, fn state ->
      with repo_data when not is_nil(repo_data) <- state.repos[repo] do
        # Determine if reference is a tag or a digest
        if Map.has_key?(repo_data.tags, reference) do
          # Tag reference – resolve to digest
          digest = repo_data.tags[reference]

          case repo_data.manifests[digest] do
            nil -> :error
            %{content: content, media_type: media} -> {:ok, content, media}
          end
        else
          # Digest reference
          case repo_data.manifests[reference] do
            nil -> :error
            %{content: content, media_type: media} -> {:ok, content, media}
          end
        end
      else
        _ -> :error
      end
    end)
  end

  def put_manifest(repo, reference, content, content_type) do
    init_repo(repo)
    # Compute the content digest of the manifest (OCI uses SHA256 of manifest bytes)
    digest = "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))

    Agent.update(__MODULE__, fn state ->
      # Store manifest by digest
      state =
        put_in(state, [:repos, repo, :manifests, digest], %{
          content: content,
          media_type: content_type
        })

      # If reference is a tag, update tag-to-digest mapping
      state =
        if reference =~ ":" do
          # If reference looks like a digest (contains ":"), we *only* store by digest (no tag).
          state
        else
          put_in(state, [:repos, repo, :tags, reference], digest)
        end

      state
    end)

    :ok
  end

  def list_tags(repo) do
    Agent.get(__MODULE__, fn state ->
      case state.repos[repo] do
        nil ->
          # repository not found
          :error

        repo_data ->
          tags = Map.keys(repo_data.tags)
          {:ok, tags}
      end
    end)
  end

  def list_repositories() do
    Agent.get(__MODULE__, fn state ->
      {:ok, Map.keys(state.repos)}
    end)
  end

  def delete_blob(repo, digest) do
    Agent.get_and_update(__MODULE__, fn state ->
      case get_in(state, [:repos, repo, :blobs, digest]) do
        nil ->
          {:error, state}

        _blob ->
          new_state = update_in(state, [:repos, repo, :blobs], &Map.delete(&1 || %{}, digest))
          {:ok, new_state}
      end
    end)
  end

  def delete_manifest(repo, reference) do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.repos[repo] do
        nil ->
          {:error, state}

        repo_data ->
          # Determine digest to delete
          digest =
            if Map.has_key?(repo_data.tags, reference) do
              repo_data.tags[reference]
            else
              reference
            end

          if Map.has_key?(repo_data.manifests, digest) do
            # Remove manifest and any tag pointing to it
            new_repo_data =
              repo_data
              |> update_in([:manifests], &Map.delete(&1, digest))
              |> update_in([:tags], fn tags_map ->
                # remove all tags mapping to this digest
                Map.filter(tags_map, fn {_tag, d} -> d != digest end)
              end)

            new_state = put_in(state, [:repos, repo], new_repo_data)
            {:ok, new_state}
          else
            {:error, state}
          end
      end
    end)
  end
end
