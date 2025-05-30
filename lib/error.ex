defmodule OCI.Error do
  @moduledoc """
  Error codes for the OCI Registry API.

  This module defines the error codes and messages for the OCI Registry API.
  It also provides a function to initialize an error struct with a given code and details.
  """
  use TypedStruct

  @errors %{
    BLOB_UNKNOWN: %{
      message: "blob unknown to registry",
      status: 404
    },
    BLOB_UPLOAD_INVALID: %{
      message: "blob upload invalid",
      status: 400
    },
    BLOB_UPLOAD_UNKNOWN: %{
      message: "blob upload unknown to registry",
      status: 404
    },
    DIGEST_INVALID: %{
      message: "provided digest did not match uploaded content",
      status: 400
    },
    MANIFEST_BLOB_UNKNOWN: %{
      message: "manifest references a manifest or blob unknown to registry",
      status: 400
    },
    MANIFEST_INVALID: %{
      message: "manifest invalid",
      status: 400
    },
    MANIFEST_UNKNOWN: %{
      message: "manifest unknown to registry",
      status: 404
    },
    NAME_INVALID: %{
      message: "invalid repository name",
      status: 400
    },
    NAME_UNKNOWN: %{
      message: "repository name not known to registry",
      status: 404
    },
    SIZE_INVALID: %{
      message: "provided length did not match content length",
      status: 400
    },
    UNAUTHORIZED: %{
      message: "authentication required",
      status: 401
    },
    DENIED: %{
      message: "requested access to the resource is denied",
      status: 403
    },
    UNSUPPORTED: %{
      message: "the operation is unsupported",
      status: 405
    },
    TOOMANYREQUESTS: %{
      message: "too many requests",
      status: 429
    },
    EXT_BLOB_UPLOAD_OUT_OF_ORDER: %{
      message: "blob upload out of order",
      status: 416
    }
  }

  @derive {Jason.Encoder, only: [:code, :message, :detail]}
  typedstruct do
    field :code, atom()
    field :message, String.t()
    field :detail, any()
    field :http_status, integer()
  end

  def init(code, details) do
    %__MODULE__{
      code: code,
      message: @errors[code][:message],
      detail: details,
      http_status: @errors[code][:status] || 500
    }
  end
end
