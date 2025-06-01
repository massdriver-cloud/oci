defmodule OCI.Auth.Adapter do
  @moduledoc """
  Adapter for authenticating requests to the OCI registry.
  """

  @type t :: struct()

  @typedoc """
  Represents the authorization header value.
  This is the full authorization header value, including the scheme and credentials.
  """
  @type authorization_t :: String.t()

  @typedoc """
  Represents the authentication scheme type.
  Currently supports "Basic" and "Bearer" authentication methods.
  """
  @type scheme_t :: String.t()

  @typedoc """
  Represents encoded credentials string.
  For Basic auth, this is the base64 encoded username:password string.
  For Bearer auth, this is the encoded token string.
  """
  @type credentials_enc_t :: String.t()

  @typedoc """
  Represents decoded credentials string.
  For Basic auth, this is the raw username:password string.
  For Bearer auth, this is the decoded token string.
  """
  @type credentials_t :: String.t()

  @typedoc """
  Represents the context of the authentication request.
  This can be used to store authentication information or other relevant data.
  """
  @type ctx_t :: map()

  @type error_details_t :: map() | String.t() | nil

  @callback init(config :: map()) :: {:ok, t()} | {:error, term()}

  @callback authenticate(auth_strategy :: t(), authorization :: authorization_t()) ::
              {:ok, context :: ctx_t()}
              | {:error, error_type :: atom(), details :: error_details_t()}

  @callback authorize(
              auth_strategy :: t(),
              context :: ctx_t(),
              action :: atom(),
              resource :: any()
            ) ::
              :ok | {:error, error_type :: atom(), details :: error_details_t()}

  @callback challenge(registry :: OCI.Registry.t()) :: {String.t(), String.t()}
end
