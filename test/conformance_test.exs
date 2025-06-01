defmodule OCI.ConformanceTest do
  # @moduledoc false
  use ExUnit.Case, async: false

  setup_all do
    :ok =
      ConformanceSuite.clone_repo(
        "https://github.com/coryodaniel/distribution-spec.git",
        "fix/patch-content-range-requirement-in-02-setup",
        force: false
      )

    :ok = ConformanceSuite.build(force: true)

    ConformanceSuite.generate_report()

    on_exit(fn ->
      config = Application.get_env(:oci, :storage)
      local_path = config[:config][:path]
      File.rm_rf!(local_path)
    end)
  end

  test "has did run conformance specs" do
    assert length(ConformanceSuite.reports()) > 0
  end

  ConformanceSuite.failures()
  |> Enum.each(fn conftest ->
    %{
      "ContainerHierarchyTexts" => container_hierarchy,
      "LeafNodeText" => leaf,
      "Failure" => %{
        "Location" => %{"FileName" => file, "LineNumber" => line},
        "Message" => message
      }
    } = conftest

    rand = Enum.random(1..1_000_000)

    name = (container_hierarchy ++ [leaf, Integer.to_string(rand)]) |> Enum.join(" ")
    location = "#{file}:#{line}"
    msg = message

    quote =
      quote do
        test unquote(name) do
          refute unquote(msg), """
          Location: #{unquote(location)}
          """
        end
      end

    Module.eval_quoted(__MODULE__, quote)
  end)
end
