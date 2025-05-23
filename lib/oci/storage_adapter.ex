defmodule OCI.StorageAdapter do
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
    @behaviour OCI.StorageAdapter

    # Implement all callbacks here
  end
  ```
  """

  @doc """
  Starts the storage adapter process.

  This is called when the registry starts up. Use this to initialize any connections
  or resources needed by your storage backend.

  ## Parameters
    - opts: Configuration options for your storage adapter

  ## Returns
    - `{:ok, pid}` on successful start
    - `{:error, reason}` on failure
  """
  @callback start_link(opts :: term) :: {:ok, pid} | {:error, term}

  @doc """
  Initializes a new repository in the storage backend.

  Called when a new repository is created. Use this to set up any necessary
  directory structures or database entries.

  ## Parameters
    - repo: The repository name (e.g., "myapp/backend")
  """
  @callback init_repo(repo :: String.t()) :: :ok

  @doc """
  Checks if a blob exists in the repository.

  ## Parameters
    - repo: The repository name
    - digest: The blob's digest (e.g., "sha256:abc123...")

  ## Returns
    - `true` if the blob exists
    - `false` if the blob doesn't exist
  """
  @callback blob_exists?(repo :: String.t(), digest :: String.t()) :: boolean

  @doc """
  Retrieves a blob's content from storage.

  ## Parameters
    - repo: The repository name
    - digest: The blob's digest

  ## Returns
    - `{:ok, binary}` containing the blob data
    - `:error` if the blob doesn't exist or can't be retrieved
  """
  @callback get_blob(repo :: String.t(), digest :: String.t()) :: {:ok, binary} | :error

  @doc """
  Stores a blob in the repository.

  ## Parameters
    - repo: The repository name
    - digest: The blob's digest
    - content: The binary content to store
  """
  @callback put_blob(repo :: String.t(), digest :: String.t(), content :: binary) :: :ok

  @doc """
  Initiates a blob upload session.

  Used for handling large blob uploads in chunks. Returns an upload ID that will be
  used in subsequent chunk uploads.

  ## Parameters
    - repo: The repository name

  ## Returns
    - `{:ok, upload_id}` where upload_id is a unique identifier for this upload session
  """
  @callback initiate_blob_upload(repo :: String.t()) :: {:ok, upload_id :: String.t()}

  @doc """
  Uploads a chunk of data to an ongoing blob upload.

  ## Parameters
    - upload_id: The ID returned from initiate_blob_upload/1
    - chunk: The binary data chunk to upload

  ## Returns
    - `{:ok, bytes_received}` indicating how many bytes were stored
    - `{:error, reason}` if the upload fails
  """
  @callback upload_chunk(upload_id :: String.t(), chunk :: binary) ::
              {:ok, pos_integer} | {:error, term}

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
  @callback finalize_blob_upload(upload_id :: String.t(), digest :: String.t()) ::
              :ok | {:error, :digest_mismatch | term}

  @doc """
  Retrieves a manifest from the repository.

  ## Parameters
    - repo: The repository name
    - reference: The manifest reference (tag or digest)

  ## Returns
    - `{:ok, content, content_type}` containing the manifest data and its content type
    - `:error` if the manifest doesn't exist or can't be retrieved
  """
  @callback get_manifest(repo :: String.t(), reference :: String.t()) ::
              {:ok, binary, content_type :: String.t()} | :error

  @doc """
  Stores a manifest in the repository.

  ## Parameters
    - repo: The repository name
    - reference: The manifest reference (tag or digest)
    - content: The manifest content
    - content_type: The manifest's content type (e.g., "application/vnd.oci.image.manifest.v1+json")

  ## Returns
    - `:ok` on success
    - `{:error, reason}` on failure
  """
  @callback put_manifest(
              repo :: String.t(),
              reference :: String.t(),
              content :: binary,
              content_type :: String.t()
            ) :: :ok | {:error, term}

  @doc """
  Lists all tags in a repository.

  ## Parameters
    - repo: The repository name

  ## Returns
    - `{:ok, [tag]}` list of tag names
    - `:error` if the repository doesn't exist or can't be accessed
  """
  @callback list_tags(repo :: String.t()) :: {:ok, [String.t()]} | :error

  @doc """
  Lists all repositories in the registry.

  ## Returns
    - `{:ok, [repo]}` list of repository names
  """
  @callback list_repositories() :: {:ok, [String.t()]}

  @doc """
  Deletes a blob from the repository.

  ## Parameters
    - repo: The repository name
    - digest: The blob's digest

  ## Returns
    - `:ok` on success
    - `:error` if the blob doesn't exist or can't be deleted
  """
  @callback delete_blob(repo :: String.t(), digest :: String.t()) :: :ok | :error

  @doc """
  Deletes a manifest from the repository.

  ## Parameters
    - repo: The repository name
    - reference: The manifest reference (tag or digest)

  ## Returns
    - `:ok` on success
    - `:error` if the manifest doesn't exist or can't be deleted
  """
  @callback delete_manifest(repo :: String.t(), reference :: String.t()) :: :ok | :error
end
