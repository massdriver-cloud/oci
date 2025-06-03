defmodule OCI.Storage.Adapter do
  @moduledoc """
  Behaviour for OCI registry storage backends.

  This module defines the interface that storage adapters must implement to work with OCI (Open Container Initiative) registries.
  A storage adapter is responsible for storing and retrieving container images and their components.

  ## Key Concepts

  - **Repository**: A collection of related container images (e.g., "myapp/backend")
  - **Blob**: Binary data that represents layers of a container image or configuration
  - **Manifest**: A JSON document that describes a container image, including its layers and configuration
  - **Digest**: A unique identifier for a blob, typically a SHA-256 hash
  - **Reference**: A human-readable identifier for a manifest (e.g., "latest", "v1.0.0")

  ## Implementation Guide

  When implementing this behaviour, you'll need to handle:
  1. Repository initialization and management
  2. Blob storage and retrieval
  3. Manifest storage and retrieval
  4. Tag management
  5. Upload handling for large blobs

  ## Example Usage

  ```elixir
  defmodule MyStorageAdapter do
    @behaviour OCI.Storage.Adapter

    defstruct [:path]  # Define your struct fields here

    # Implement all callbacks here
  end
  ```
  """

  @type t :: struct()

  @type error_details_t :: any()

  @doc """
  Initializes a new storage adapter instance with the given configuration.

  ## Parameters
    - config: The configuration for the storage adapter

  ## Returns
    - A new storage adapter instance
  """
  @callback init(config :: map()) :: {:ok, t()} | {:error, term()}

  @doc """
  Initiates a blob upload session.

  Used for handling large blob uploads in chunks. Returns an upload ID that will be
  used in subsequent chunk uploads.

  ## Parameters
    - repo: The repository name

  ## Returns
    - `{:ok, upload_id}` where upload_id is a unique identifier for this upload session
  """
  @callback initiate_blob_upload(storage :: t(), repo :: String.t()) ::
              {:ok, upload_id :: String.t()} | {:error, term()}

  @doc """
  Mounts a blob from one repository to another.

  ## Parameters
    - storage: The storage adapter instance
    - repo: The repository name
    - from_repo: The source repository name
    - digest: The digest of the blob to mount

  ## Returns
    - `:ok` if the mount is successful
    - `{:error, :BLOB_UNKNOWN}` if the blob doesn't exist in the source repository
  """
  @callback mount_blob(
              storage :: t(),
              repo :: String.t(),
              digest :: String.t(),
              from_repo :: String.t()
            ) ::
              :ok | {:error, :BLOB_UNKNOWN}

  @doc """
  Uploads a chunk of data to an ongoing blob upload.

  ## Parameters
    - storage: The storage adapter instance
    - repo: The repository name
    - uuid: The upload session ID
    - chunk: The binary data chunk to upload
    - content_range: The range of bytes being uploaded (e.g. "0-1023")

  ## Returns
    - `{:ok, range}` indicating the current range of **total**uploaded bytes
    - `{:error, reason}` if the upload fails
  """
  @callback upload_chunk(
              storage :: t(),
              repo :: String.t(),
              uuid :: String.t(),
              chunk :: binary(),
              content_range :: String.t()
            ) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Gets the status of an ongoing blob upload.

  ## Parameters
    - storage: The storage adapter instance
    - repo: The repository name
    - uuid: The upload session ID

  ## Returns
    - `{:ok, range}` where range is the current range of uploaded bytes
    - `{:error, :BLOB_UPLOAD_UNKNOWN}` if the upload doesn't exist
  """
  @callback get_upload_status(
              storage :: t(),
              repo :: String.t(),
              uuid :: String.t()
            ) ::
              {:ok, String.t()} | {:error, term()}

  @callback get_upload_size(storage :: t(), repo :: String.t(), uuid :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Finalizes a blob upload and verifies the digest.

  ## Parameters
    - upload_id: The ID of the upload to finalize
    - digest: The expected digest of the complete blob

  ## Returns
    - `:ok` if the upload is successful and digest matches
    - `{:error, :digest_mismatch}` if the calculated digest doesn't match
    - `{:error, reason}` for other failures
  """
  @callback complete_blob_upload(
              storage :: t(),
              repo :: String.t(),
              upload_id :: String.t(),
              digest :: String.t()
            ) ::
              :ok | {:error, :digest_mismatch | term}

  @callback repo_exists?(storage :: t(), repo :: String.t()) :: boolean()

  @callback cancel_blob_upload(storage :: t(), repo :: String.t(), uuid :: String.t()) ::
              :ok | {:error, :BLOB_UPLOAD_UNKNOWN}

  @callback blob_exists?(storage :: t(), repo :: String.t(), digest :: String.t()) ::
              {:ok, size :: non_neg_integer()} | {:error, :BLOB_UNKNOWN}

  @callback get_blob(storage :: t(), repo :: String.t(), digest :: String.t()) ::
              {:ok, content :: binary()} | {:error, :BLOB_UNKNOWN}

  @callback delete_blob(storage :: t(), repo :: String.t(), digest :: String.t()) ::
              :ok | {:error, :BLOB_UNKNOWN}

  @callback put_manifest(
              storage :: t(),
              repo :: String.t(),
              reference :: String.t(),
              manifest :: map(),
              manifest_digest :: String.t()
            ) ::
              :ok
              | {:error, :MANIFEST_BLOB_UNKNOWN | :MANIFEST_INVALID | :NAME_UNKNOWN,
                 error_details_t}

  @callback get_manifest(t(), repo :: String.t(), reference :: String.t()) ::
              {:ok, manifest :: binary(), content_type :: String.t()}
              | {:error, atom(), error_details_t}

  @callback head_manifest(t(), repo :: String.t(), reference :: String.t()) ::
              {:ok, content_type :: String.t(), byte_size :: non_neg_integer()}
              | {:error, atom(), error_details_t}

  @callback delete_manifest(t(), String.t(), String.t()) :: :ok | {:error, atom()}

  @callback list_tags(t(), String.t(), OCI.Registry.Pagination.t()) ::
              {:ok, [String.t()]} | {:error, :NAME_UNKNOWN}
end
