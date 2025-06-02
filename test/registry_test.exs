defmodule OCI.RegistryTest do
  use ExUnit.Case, async: true
  doctest OCI.Registry

  defp tmp_storage() do
    OCI.Storage.Local.init(%{path: "./tmp/"})
  end

  defp static_auth(username, password) do
    OCI.Auth.Static.init(%{users: [%{username: username, password: password}]})
  end

  defp registry_with_user(username, password) do
    {:ok, storage} = tmp_storage()
    {:ok, auth} = static_auth(username, password)
    {:ok, registry} = OCI.Registry.init(storage: storage, auth: auth)
    registry
  end

  describe "authenticate" do
    test "returns {:ok, ctx} when authentication is successful" do
      registry = registry_with_user("myuser", "mypass")

      authorization = "Basic #{Base.encode64("myuser:mypass")}"
      assert {:ok, subject} = OCI.Registry.authenticate(registry, authorization)
      assert subject == "myuser"
    end

    test "returns {:error, :UNAUTHORIZED} when authentication is unsuccessful" do
      registry = registry_with_user("myuser", "mypass")

      authorization = "Basic #{Base.encode64("myuser:wrongpass")}"
      assert {:error, :UNAUTHORIZED, _} = OCI.Registry.authenticate(registry, authorization)
    end
  end

  describe "authorize" do
    test "returns :ok when authorization is successful" do
      user = %OCI.Auth.Static.User{
        username: "myuser",
        password: "mypass",
        permissions: %{"myimage" => ["pull", "push"]}
      }

      {:ok, auth} = OCI.Auth.Static.init(%{users: [user]})
      {:ok, storage} = tmp_storage()
      {:ok, registry} = OCI.Registry.init(storage: storage, auth: auth)

      ctx = %OCI.Context{
        repo: "myimage",
        subject: "myuser",
        method: "GET",
        endpoint: :blobs_uploads,
        resource: "myuser"
      }

      assert :ok = OCI.Registry.authorize(registry, ctx)
    end
  end

  describe "challenge" do
    test "returns {scheme, auth_param} when challenge is successful" do
      registry = registry_with_user("doesnt", "matter")
      registry = %{registry | realm: "test"}
      {scheme, auth_param} = OCI.Registry.challenge(registry)
      assert scheme == "Basic"
      assert auth_param == "realm=\"test\""
    end
  end
end
