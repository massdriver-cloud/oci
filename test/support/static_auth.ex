defmodule OCI.Auth.StaticAuth do
  @moduledoc """
  A static authentication adapter for testing.
  """

  @behaviour OCI.Auth.Adapter

  use TypedStruct

  typedstruct do
  end

  @impl true
  def init(_config) do
    {:ok, %__MODULE__{}}
  end

  @impl true
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

  @impl true
  def authorize(%{subject: "myuser"}, _action, _resource) do
    :ok
  end

  @impl true
  def authorize(_ctx, _action, _resource) do
    {:error, :UNAUTHORIZED}
  end

  @impl true
  def challenge(registry) do
    {"Basic", ~s(realm="#{registry.realm}")}
  end
end
