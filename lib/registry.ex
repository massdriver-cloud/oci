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
    - chunk_range: The length of the chunk

  ## Returns
    - `{:ok, location, range}` where location is the URL for the next chunk upload and range is the current range of uploaded bytes
    - `{:error, reason}` if the upload fails
  """

  # Ok, so we can't guarantee content-range, so we'll have to make it up to prevent overlap test.
  # Adding this in breaks everything, removing it breaks 5 things (only three if we never send content range in the first place)
  # def upload_chunk(%{storage: storage}, repo, uuid, chunk, nil) do
  #   content_range = "0-#{byte_size(chunk) - 1}"
  #   upload_chunk(storage, repo, uuid, chunk, content_range)
  # end

  def upload_chunk(%{storage: storage}, repo, uuid, chunk, nil) do
    chunk_range = calculate_range(chunk)
    upload_chunk(storage, repo, uuid, chunk, chunk_range)
  end

  def upload_chunk(%{storage: storage}, repo, uuid, chunk, chunk_range) do
    reg = adapter(storage)

    case reg.upload_exists?(storage, repo, uuid) do
      :ok ->
        IO.inspect(chunk_range, label: "=========== CHUNK RANGE ===========")
        {:ok, size} = reg.get_upload_size(storage, repo, uuid)
        IO.inspect(size, label: "=========== SIZE ===========")

        result = storage.__struct__.upload_chunk(storage, repo, uuid, chunk, chunk_range)
        IO.inspect(result, label: "=========== RESULT (IF ORDER WAS OK...) ===========")

        # Something about this breaks 26 calls, but worse is that the output is lost in phx500.
        # => the nil value, my hypothesis, so what happens when we nil check with and without
        #    the line below?
        #
        #    # nil check, verify
        #    #  [   ]        [   ] = 4 broke tests
        #    #  [   ]        [ x ] = 30 broke tests (EXT_ val errors present!)
        #    #  [ x ]        [   ] = 30 broke tests
        #    #  [ x ]        [ x ] = 30 broke tests (EXT_ val errors present!)
        #
        # [-] Disable nil check, and work through verify:
        #   [ ] Effect on conf test failures?
        # [ ] How does calculate range also break in nil checking?
        #
        order_ok = verify_upload_order(size, chunk_range)
        IO.inspect(order_ok, label: "=========== ORDER OK ===========")

        case result do
          {:ok, range} ->
            {:ok, blobs_uploads_path(repo, uuid), range}

          error ->
            error
        end

      err ->
        err
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
    iex> OCI.Registry.calculate_range("hello")
    "0-4"
    iex> OCI.Registry.calculate_range("hello", 1)
    "1-5"
  """
  @spec calculate_range(bitstring(), non_neg_integer() | nil) :: nonempty_binary()

  def calculate_range(data, start_byte \\ 0) do
    end_byte = start_byte + byte_size(data) - 1
    "#{start_byte}-#{end_byte}"
  end

  defp adapter(%{__struct__: a}), do: a

  defp parse_range(range) do
    [range_start, range_end] = String.split(range, "-") |> Enum.map(&String.to_integer/1)
    {range_start, range_end}
  end

  # TODO: it looks like an empty blob {"0", nil} is being uploaded
  # What happens if we turn nil checking on, this will be set (to something weird)
  # What do we do in this scenario, is this an error that the conftest can handle?
  #
  # if we turn nil checking ON this get skipped and
  defp verify_upload_order(current_size, nil) do
    require IEx
    IEx.pry()
  end

  defp verify_upload_order(current_size, range) do
    OCI.Inspector.pry(binding())

    {range_start, range_end} = parse_range(range)

    if range_start == current_size do
      :ok
    else
      {:error, :EXT_BLOB_UPLOAD_OUT_OF_ORDER}
    end
  end
end
