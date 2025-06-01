defmodule OCI.Auth.Static do
  @moduledoc """
  A static authentication adapter for development.
  """

  @behaviour OCI.Auth.Adapter

  use TypedStruct

  typedstruct module: User do
    field :username, String.t(), enforce: true
    field :password, String.t(), enforce: true
  end

  typedstruct do
    field :users, list(User.t()), enforce: true
  end

  @impl true
  def init(config) do
    {:ok, %__MODULE__{users: config.users}}
  end

  @impl true
  def authenticate(auth, authorization) do
    [scheme, credentials_enc] = String.split(authorization, " ", parts: 2)

    case scheme do
      "Basic" ->
        case Base.decode64(credentials_enc) do
          {:ok, credentials} ->
            case String.split(credentials, ":") do
              [username, password] ->
                if Enum.find(auth.users, fn user ->
                     user.username == username && user.password == password
                   end) do
                  {:ok, %{subject: username}}
                else
                  {:error, :UNAUTHORIZED, "Invalid username or password"}
                end

              _ ->
                {:error, :UNAUTHORIZED,
                 "Invalid authorization format, should be username:password"}
            end

          :error ->
            {:error, :UNAUTHORIZED,
             "Failed to decode authorization, should be base64 encoded username:password"}
        end

      _other ->
        {:error, :UNSUPPORTED, "Unsupported authentication scheme: #{scheme}"}
    end
  end

  @impl true
  def authorize(_auth, _ctx, _action, _resource) do
    # TODO: add repos permissions to static and authorize here
    :ok
  end

  @impl true
  def authorize(_auth, _ctx, _action, _resource) do
    {:error, :UNAUTHORIZED}
  end

  @impl true
  def challenge(registry) do
    {"Basic", ~s(realm="#{registry.realm}")}
  end
end
