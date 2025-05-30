defmodule OCI.Registry do
  @moduledoc """
  Registry wraps storage and auth adapters and handles common logic for OCI
  like validating manifests and tags.
  """

  @behaviour OCI.Storage.Adapter

  use TypedStruct

  typedstruct do
    field :realm, String.t(), enforce: false, default: "Registry"
    field :storage, module(), enforce: true
    field :max_manifest_size, pos_integer(), enforce: false, default: 4 * 1024 * 1024
    field :max_blob_upload_chunk_size, pos_integer(), enforce: false, default: 10 * 1024 * 1024
    field :enable_blob_deletion, boolean(), enforce: false, default: true
    field :enable_manifest_deletion, boolean(), enforce: false, default: true
  end

  typedstruct module: Pagination do
    field :n, pos_integer(), enforce: false
    field :last, String.t(), enforce: false
  end

  @doc """
  Initializes a new registry instance with the given configuration.
  """
  def init(opts) do
    storage = Keyword.fetch!(opts, :storage)
    %__MODULE__{storage: storage}
  end

  def repo_exists?(%{storage: storage}, repo) do
    storage.__struct__.repo_exists?(storage, repo)
  end

  @doc """
  Initiates a new blob upload for the given repository.
  Returns {:ok, location} on success or {:error, reason} on failure.
  The location is the full path where the blob should be uploaded.
  """
  def initiate_blob_upload(%{storage: storage}, repo) do
    case storage.__struct__.initiate_blob_upload(storage, repo) do
      {:ok, uuid} -> {:ok, blobs_uploads_path(repo, uuid)}
      error -> error
    end
  end

  @doc """
  Uploads a chunk of data to an existing blob upload.

  ## Parameters
    - registry: The registry instance
    - repo: The repository name
    - uuid: The upload session ID
    - chunk: The binary data chunk to upload
    - content_length: The length of the chunk

  ## Returns
    - `{:ok, location, range}` where location is the URL for the next chunk upload and range is the current range of uploaded bytes
    - `{:error, reason}` if the upload fails
  """
  def upload_chunk(%{storage: storage}, repo, uuid, chunk, content_length) do
    case storage.__struct__.upload_chunk(storage, repo, uuid, chunk, content_length) do
      {:ok, range} ->
        {:ok, blobs_uploads_path(repo, uuid), range}

      error ->
        error
    end
  end

  @doc """
  Gets the status of an ongoing blob upload.

  ## Parameters
    - registry: The registry instance
    - repo: The repository name
    - uuid: The upload session ID

  ## Returns
    - `{:ok, location, range}` where location is the URL for the next chunk upload and range is the current range of uploaded bytes
    - `{:error, :BLOB_UPLOAD_UNKNOWN}` if the upload doesn't exist
  """
  def get_upload_status(%{storage: storage}, repo, uuid) do
    case storage.__struct__.get_upload_status(storage, repo, uuid) do
      {:ok, range} ->
        {:ok, blobs_uploads_path(repo, uuid), range}

      {:error, :BLOB_UPLOAD_UNKNOWN} ->
        {:error, :BLOB_UPLOAD_UNKNOWN}
    end
  end

  def complete_blob_upload(_registry, _repo, _uuid, nil), do: {:error, :DIGEST_INVALID}

  def complete_blob_upload(%{storage: storage}, repo, uuid, digest) do
    case storage.__struct__.complete_blob_upload(
           storage,
           repo,
           uuid,
           digest
         ) do
      :ok -> {:ok, blobs_digest_path(repo, digest)}
      error -> error
    end
  end

  def cancel_blob_upload(%{storage: storage}, repo, uuid) do
    storage.__struct__.cancel_blob_upload(storage, repo, uuid)
  end

  def blob_exists?(%{storage: storage}, repo, digest) do
    storage.__struct__.blob_exists?(storage, repo, digest)
  end

  def get_blob(%{storage: storage}, repo, digest) do
    storage.__struct__.get_blob(storage, repo, digest)
  end

  def delete_blob(%{enable_blob_deletion: false}, _repo, _digest), do: {:error, :UNSUPPORTED}

  def delete_blob(%{storage: storage}, repo, digest) do
    storage.__struct__.delete_blob(storage, repo, digest)
  end

  def delete_manifest(%{enable_manifest_deletion: false}, _repo, _reference),
    do: {:error, :UNSUPPORTED}

  def delete_manifest(%{storage: storage}, repo, reference) do
    if String.starts_with?(reference, "sha256:") do
      storage.__struct__.delete_manifest(storage, repo, reference)
    else
      {:error, :MANIFEST_INVALID}
    end
  end

  def put_manifest(%{storage: storage}, repo, reference, manifest, content_type) do
    storage.__struct__.put_manifest(
      storage,
      repo,
      reference,
      manifest,
      content_type
    )
  end

  def get_manifest(%{storage: storage}, repo, reference) do
    storage.__struct__.get_manifest(storage, repo, reference)
  end

  def head_manifest(%{storage: storage}, repo, reference) do
    storage.__struct__.head_manifest(storage, repo, reference)
  end

  def list_tags(%{storage: storage}, repo, pagination) do
    storage.__struct__.list_tags(storage, repo, pagination)
  end

  def sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  def verify_digest(data, digest) do
    case digest do
      "sha256:" <> hash ->
        computed = sha256(data)

        if computed == hash, do: :ok, else: {:error, :DIGEST_INVALID}

      _ ->
        {:error, :DIGEST_INVALID}
    end
  end

  @doc """
  Mounts a blob from one repository to another.
  Returns {:ok, location} on success, {:error, :BLOB_UNKNOWN} if the source blob doesn't exist.
  """
  def mount_blob(%__MODULE__{storage: storage} = registry, repo, digest, from_repo) do
    case repo_exists?(registry, from_repo) do
      false ->
        {:error, :NAME_UNKNOWN}

      true ->
        case blob_exists?(registry, from_repo, digest) do
          {:error, :BLOB_UNKNOWN} ->
            initiate_blob_upload(registry, repo)

          {:ok, _size} ->
            case storage.__struct__.mount_blob(storage, repo, digest, from_repo) do
              :ok -> {:ok, blobs_digest_path(repo, digest)}
              error -> error
            end
        end
    end
  end

  defp blobs_digest_path(repo, digest) do
    "/v2/#{repo}/blobs/#{digest}"
  end

  defp blobs_uploads_path(repo, uuid) do
    "/v2/#{repo}/blobs/uploads/#{uuid}"
  end
end
