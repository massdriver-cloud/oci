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

  alias OCI.Registry

  @type t :: struct()

  @type error_details_t :: map()

  @doc """
  Checks if a blob exists in the repository and returns its size if found.
  """
  @callback blob_exists?(
              storage :: t(),
              repo :: Registry.repo_t(),
              digest :: Registry.digest_t(),
              ctx :: OCI.Context.t()
            ) ::
              boolean()

  @doc """
  Cancels an ongoing blob upload session.
  """
  @callback cancel_blob_upload(
              storage :: t(),
              repo :: Registry.repo_t(),
              uuid :: Registry.uuid_t(),
              ctx :: OCI.Context.t()
            ) ::
              :ok
              | {:error, :BLOB_UPLOAD_UNKNOWN, error_details_t}

  @doc """
  Finalizes a blob upload and verifies the digest.
  """
  @callback complete_blob_upload(
              storage :: t(),
              repo :: Registry.repo_t(),
              upload_id :: Registry.uuid_t(),
              digest :: Registry.digest_t(),
              ctx :: OCI.Context.t()
            ) ::
              :ok | {:error, atom(), error_details_t}

  @doc """
  Deletes a blob from the repository.
  """
  @callback delete_blob(
              storage :: t(),
              repo :: Registry.repo_t(),
              digest :: Registry.digest_t(),
              ctx :: OCI.Context.t()
            ) ::
              :ok | {:error, :BLOB_UNKNOWN, error_details_t}

  @doc """
  Deletes a manifest from the repository.
  """
  @callback delete_manifest(
              storage :: t(),
              repo :: Registry.repo_t(),
              reference :: Registry.reference_t(),
              ctx :: OCI.Context.t()
            ) ::
              :ok | {:error, atom(), error_details_t}

  @doc """
  Retrieves a blob's content from the repository.
  """
  @callback get_blob(
              storage :: t(),
              repo :: Registry.repo_t(),
              digest :: Registry.digest_t(),
              ctx :: OCI.Context.t()
            ) ::
              {:ok, content :: binary()}
              | {:error, :BLOB_UNKNOWN, error_details_t}

  @doc """
  Retrieves a manifest from the repository.
  """
  @callback get_manifest(
              storage :: t(),
              repo :: Registry.repo_t(),
              reference :: Registry.reference_t(),
              ctx :: OCI.Context.t()
            ) ::
              {:ok, manifest :: binary(), content_type :: String.t()}
              | {:error, :MANIFEST_UNKNOWN, error_details_t}

  @doc """
  Gets the status of an ongoing blob upload.
  """
  @callback get_blob_upload_status(
              storage :: t(),
              repo :: Registry.repo_t(),
              uuid :: Registry.uuid_t(),
              ctx :: OCI.Context.t()
            ) ::
              {:ok, range :: String.t()} | {:error, :BLOB_UPLOAD_UNKNOWN, error_details_t}

  @doc """
  Gets the total size of an ongoing blob upload.
  """
  @callback get_blob_upload_offset(
              storage :: t(),
              repo :: Registry.repo_t(),
              uuid :: Registry.uuid_t(),
              ctx :: OCI.Context.t()
            ) ::
              {:ok, size :: non_neg_integer()}
              | {:error, :BLOB_UPLOAD_UNKNOWN, error_details_t}

  @doc """
  Gets metadata about a manifest without retrieving its content.
  """
  @callback manifest_exists?(
              storage :: t(),
              repo :: Registry.repo_t(),
              reference :: Registry.reference_t(),
              ctx :: OCI.Context.t()
            ) ::
              boolean()

  @doc """
  Initializes a new storage adapter instance with the given configuration.
  """
  @callback init(config :: map()) ::
              {:ok, storage :: t()} | {:error, atom(), error_details_t}

  @doc """
  Initiates a blob upload session.
  """
  @callback initiate_blob_upload(
              storage :: t(),
              repo :: Registry.repo_t(),
              ctx :: OCI.Context.t()
            ) ::
              {:ok, upload_id :: Registry.uuid_t()}
              | {:error, atom(), error_details_t}

  @doc """
  Lists tags in a repository with pagination support.
  """
  @callback list_tags(
              storage :: t(),
              repo :: Registry.repo_t(),
              pagination :: OCI.Pagination.t(),
              ctx :: OCI.Context.t()
            ) ::
              {:ok, tags :: [Registry.tag_t()]}
              | {:error, :NAME_UNKNOWN, error_details_t}

  @doc """
  Mounts a blob from one repository to another.
  """
  @callback mount_blob(
              storage :: t(),
              repo :: Registry.repo_t(),
              digest :: Registry.digest_t(),
              from_repo :: Registry.repo_t(),
              ctx :: OCI.Context.t()
            ) ::
              :ok | {:error, :BLOB_UNKNOWN, error_details_t}

  @doc """
  Stores a manifest in the repository.
  """
  @callback store_manifest(
              storage :: t(),
              repo :: Registry.repo_t(),
              reference :: Registry.reference_t(),
              manifest :: map(),
              manifest_digest :: Registry.digest_t(),
              ctx :: OCI.Context.t()
            ) ::
              :ok
              | {:error, atom(), error_details_t}

  @doc """
  Checks if a repository exists.
  """
  @callback repo_exists?(storage :: t(), repo :: Registry.repo_t(), ctx :: OCI.Context.t()) ::
              boolean()

  @doc """
  Uploads a chunk of data to an ongoing blob upload.
  """
  @callback upload_blob_chunk(
              storage :: t(),
              repo :: Registry.repo_t(),
              uuid :: Registry.uuid_t(),
              chunk :: binary(),
              content_range :: String.t(),
              ctx :: OCI.Context.t()
            ) ::
              {:ok, range :: String.t()}
              | {:error, atom(), error_details_t}

  @doc """
  Lists manifest descriptors that reference the given subject digest.

  The `filters` map may contain:
    - `"artifactType"` - filter referrers by artifact type
  """
  @callback list_referrers(
              storage :: t(),
              repo :: Registry.repo_t(),
              subject_digest :: Registry.digest_t(),
              filters :: map(),
              ctx :: OCI.Context.t()
            ) ::
              {:ok, [map()]}

  @doc """
  Stores a referrer descriptor for a given subject digest.
  """
  @callback put_referrer(
              storage :: t(),
              repo :: Registry.repo_t(),
              subject_digest :: Registry.digest_t(),
              descriptor :: map(),
              ctx :: OCI.Context.t()
            ) ::
              :ok

  @doc """
  Checks if an upload exists.
  """
  @callback upload_exists?(
              storage :: t(),
              repo :: Registry.repo_t(),
              uuid :: Registry.uuid_t(),
              ctx :: OCI.Context.t()
            ) ::
              boolean()
end
