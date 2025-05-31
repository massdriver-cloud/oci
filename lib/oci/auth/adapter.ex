defmodule OCI.Auth.Adapter do
  @moduledoc """
  Adapter for authenticating requests to the OCI registry.

  # TODO: back this out to an adapter
  # TODO: integrate into registry
  """

  @doc """
  Authenticate the given credentials using the specified authentication scheme.
  """
  @spec authenticate(authorization :: String.t()) :: {:ok, any()} | {:error, any()}
  def authenticate(authorization) do
    [scheme, credentials_enc] = String.split(authorization, " ", parts: 2)

    case scheme do
      "Basic" ->
        case Base.decode64(credentials_enc) do
          {:ok, credentials} ->
            # TODO: dont hard code auth :P
            case String.split(credentials, ":") do
              ["myuser", "mypass"] ->
                {:ok, %{subject: "myuser"}}

              _ ->
                {:error, :UNAUTHORIZED}
            end

          :error ->
            {:error, :UNAUTHORIZED}
        end

      _ ->
        # TODO: expand all errors to be able to include details
        # details = %{"scheme" => scheme, "reason" => "Unsupported authentication scheme"}
        {:error, :UNSUPPORTED}
    end
  end

  def authorize(%{subject: "myuser"}, _action, _resource) do
    :ok
  end

  def authorize(_ctx, _action, _resource) do
    {:error, :UNAUTHORIZED}
  end

  def challenge(registry) do
    {"Basic", ~s(realm="#{registry.realm}")}
  end
end
