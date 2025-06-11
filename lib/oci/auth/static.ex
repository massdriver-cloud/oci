# credo:disable-for-this-file
defmodule OCI.Auth.Static do
  @moduledoc """
  Static auth adapter for OCI.

  This adapter is used to authenticate requests using a static list of users and their permissions.

  Useful for testing and development. You shouldn't use it in production.
  """

  @behaviour OCI.Auth.Adapter

  use TypedStruct

  typedstruct module: User do
    field :username, String.t(), enforce: true
    field :password, String.t(), enforce: true

    # Map of repo name → list of actions (e.g. ["pull", "push"])
    field :permissions, %{String.t() => [String.t()]}, default: %{}
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
                  subject = username
                  {:ok, subject}
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
  def authorize(_, %OCI.Context{endpoint: :ping}), do: :ok

  def authorize(%__MODULE__{users: users}, %OCI.Context{} = ctx) do
    case Enum.find(users, &(&1.username == ctx.subject)) do
      %{permissions: perms} ->
        repo_perms = Map.get(perms, ctx.repo, [])

        case required_action(ctx.method, ctx.endpoint) do
          nil ->
            {:error, :DENIED}

          action ->
            if action in repo_perms do
              :ok
            else
              {:error, :DENIED}
            end
        end

      _ ->
        {:error, :DENIED}
    end
  end

  @impl true
  def challenge(registry) do
    {"Basic", ~s(realm="#{registry.realm}")}
  end

  defp required_action("GET", _), do: "pull"
  defp required_action("HEAD", _), do: "pull"
  defp required_action("PATCH", _), do: "push"
  defp required_action("POST", _), do: "push"
  defp required_action("PUT", _), do: "push"
  defp required_action("DELETE", _), do: "push"

  defp required_action(_, _), do: nil
end
