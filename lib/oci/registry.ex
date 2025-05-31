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

  **Note:** The Content-Range header is not always present in chunk uploads:
  - For PATCH requests, Content-Range is required (validated at plug level)
  - For POST (initial) and PUT (final) requests, Content-Range is optional
  - For monolithic uploads, Content-Range may be omitted entirely

  The `maybe_chunk_range` parameter reflects this variability in the protocol.
  We cannot assume or calculate the range ourselves because:
  1. Previous chunks may have been uploaded out of order
  2. The client may be using a different upload strategy
  3. The range is only meaningful when provided by the client

  ## Parameters
    - registry: The registry instance
    - repo: The repository name
    - uuid: The upload session ID
    - chunk: The binary data chunk to upload
    - maybe_chunk_range: Optional Content-Range header value

  ## Returns
    - `{:ok, location, range}` where location is the URL for the next chunk upload and range is the current range of uploaded bytes
    - `{:error, reason}` if the upload fails
  """
  def upload_chunk(%{storage: storage}, repo, uuid, chunk, maybe_chunk_range) do
    reg = adapter(storage)

    with :ok <- reg.upload_exists?(storage, repo, uuid),
         {:ok, size} <- reg.get_upload_size(storage, repo, uuid),
         :ok <- verify_upload_order(size, maybe_chunk_range),
         {:ok, range} <- reg.upload_chunk(storage, repo, uuid, chunk, maybe_chunk_range) do
      {:ok, blobs_uploads_path(repo, uuid), range}
    end
  end

  @doc """
  Gets the status of an ongoing blob upload.

  ## Parameters
    - registry: The registry instance
    - repo: The repository name
    - uuid: The upload session ID

  ## Returns
    - `{:ok, range}` where range is the current range of uploaded bytes
    - `{:error, :BLOB_UPLOAD_UNKNOWN}` if the upload doesn't exist
  """
  def get_upload_status(%{storage: storage}, repo, uuid) do
    case storage.__struct__.get_upload_status(storage, repo, uuid) do
      {:ok, range} -> {:ok, blobs_uploads_path(repo, uuid), range}
      error -> error
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

  @doc """
  Calculates the SHA-256 hash of the given data and returns it as a lowercase hexadecimal string.
  ## Parameters
    - data: The binary data to hash
  ## Returns
    A lowercase hexadecimal string representing the SHA-256 hash.
  ## Examples
      iex> OCI.Registry.sha256("hello")
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  """
  @spec sha256(binary()) :: String.t()
  def sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies that the given data matches the provided digest.
  ## Parameters
    - data: The binary data to verify
    - digest: The digest to verify against (must start with "sha256:")
  ## Returns
    - `:ok` if the data matches the digest
    - `{:error, :DIGEST_INVALID}` if the digest is invalid or doesn't match
  ## Examples
      iex> OCI.Registry.verify_digest("hello", "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
      :ok
      iex> OCI.Registry.verify_digest("hello", "sha256:wronghash")
      {:error, :DIGEST_INVALID}
      iex> OCI.Registry.verify_digest("hello", "invalid-digest")
      {:error, :DIGEST_INVALID}
  """
  @spec verify_digest(binary(), String.t()) :: :ok | {:error, :DIGEST_INVALID}
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

  @doc """
  Generates the path for a blob with the given digest in a repository.
  ## Parameters
    - repo: The repository name
    - digest: The digest of the blob (e.g. "sha256:abc123...")
  ## Returns
    A string representing the full path to the blob.
  ## Examples
      iex> OCI.Registry.blobs_digest_path("myrepo", "sha256:abc123")
      "/v2/myrepo/blobs/sha256:abc123"
  """
  @spec blobs_digest_path(String.t(), String.t()) :: String.t()
  def blobs_digest_path(repo, digest) do
    "/v2/#{repo}/blobs/#{digest}"
  end

  @doc """
  Generates the path for an ongoing blob upload session.
  ## Parameters
    - repo: The repository name
    - uuid: The unique identifier for the upload session
  ## Returns
    A string representing the full path to the upload session.
  ## Examples
      iex> OCI.Registry.blobs_uploads_path("myrepo", "123e4567-e89b-12d3-a456-426614174000")
      "/v2/myrepo/blobs/uploads/123e4567-e89b-12d3-a456-426614174000"
  """
  @spec blobs_uploads_path(String.t(), String.t()) :: String.t()
  def blobs_uploads_path(repo, uuid) do
    "/v2/#{repo}/blobs/uploads/#{uuid}"
  end

  @doc """
  Calculates the range of a chunk of data.
  ## Examples
    iex> OCI.Registry.calculate_range("hello", 0)
    "0-4"
    iex> OCI.Registry.calculate_range("hello", 1)
    "1-5"
  """
  @spec calculate_range(bitstring(), non_neg_integer() | nil) :: nonempty_binary()
  def calculate_range(data, start_byte) do
    end_byte = start_byte + byte_size(data) - 1
    "#{start_byte}-#{end_byte}"
  end

  @doc """
  Extracts the module name from a struct.

  ## Examples
      iex> OCI.Registry.adapter(%OCI.Storage.Local{path: "/tmp"})
      OCI.Storage.Local
  """
  @spec adapter(%{__struct__: module()}) :: module()
  def adapter(%{__struct__: a}), do: a

  @doc """
  Parses a Content-Range header value into start and end positions.

  ## Parameters
    - range: A string in the format "start-end" (e.g. "0-1023")

  ## Returns
    A tuple of {start, end} integers

  ## Examples
      iex> OCI.Registry.parse_range("0-1023")
      {0, 1023}
      iex> OCI.Registry.parse_range("1024-2047")
      {1024, 2047}
  """
  @spec parse_range(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def parse_range(range) do
    [range_start, range_end] = String.split(range, "-") |> Enum.map(&String.to_integer/1)
    {range_start, range_end}
  end

  @doc """
  Verifies that a chunk upload is in the correct order.

  When no range is provided (nil), the upload is considered valid. This is used for
  initial POST requests and final PUT requests where ranges are not required.

  ## Content-Range header requirements for chunk uploads:

  - Required for PATCH requests (validated at plug level)
  - Must be inclusive on both ends (e.g. "0-1023")
  - First chunk must begin with 0
  - Chunks must be uploaded in order
  - Not required for initial POST or final PUT requests

  **Note:** While nil ranges are valid for POST/PUT, this is a potential security concern
      as it could allow empty chunk uploads. This is handled by requiring Content-Range
      for PATCH requests at the plug level, preventing empty chunk uploads before they
      reach this verification step.

  ## Parameters
    - current_size: The current size of uploaded data in bytes
    - range: The Content-Range header value or nil

  ## Returns
    - `:ok` if the upload is valid
    - `{:error, :EXT_BLOB_UPLOAD_OUT_OF_ORDER}` if the chunk is out of order

  ## Examples
      iex> OCI.Registry.verify_upload_order(0, nil)
      :ok
      iex> OCI.Registry.verify_upload_order(1024, "1024-2047")
      :ok
      iex> OCI.Registry.verify_upload_order(1024, "2048-3071")
      {:error, :EXT_BLOB_UPLOAD_OUT_OF_ORDER}
  """

  @spec verify_upload_order(non_neg_integer(), nil | String.t()) ::
          :ok | {:error, :EXT_BLOB_UPLOAD_OUT_OF_ORDER}
  def verify_upload_order(_current_size, nil) do
    :ok
  end

  def verify_upload_order(current_size, range) do
    {range_start, _range_end} = parse_range(range)

    if range_start == current_size do
      :ok
    else
      {:error, :EXT_BLOB_UPLOAD_OUT_OF_ORDER}
    end
  end
end
