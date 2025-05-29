# TODO: duplicate tests for the OrgTeamImage router

# This file defines test-only Phoenix router modules used to verify how
# `OCI.PhoenixRouter` integrates into real-world route structures.
#
# The OCI Distribution Spec intentionally leaves repository path structure
# undefined, allowing each implementation to determine its own conventions.
# These routers simulate common patterns used in container registries:
#
# - Namespace + Name (e.g. `library/alpine`)
# - Org + Team + Image (e.g. `company/team/service`)
#
# Each test router is used in ExUnit tests to assert proper route matching,
# Plug dispatch, and helper generation across different repo configurations.

defmodule NamespaceNameRouter do
  @moduledoc """
  Test router simulating a registry with `:namespace/:name` repo structure.

  Example matching path:
    /v2/elixir/plug/tags/list
  """
  use Phoenix.Router
  import OCI.PhoenixRouter

  scope "/v2" do
    oci_routes(repo: ":namespace/:name")
  end
end

defmodule OrgTeamImageRouter do
  @moduledoc """
  Test router simulating a registry with `:org/:team/:image` repo structure.

  Example matching path:
    /v2/acme/payments/api/tags/list
  """
  use Phoenix.Router
  import OCI.PhoenixRouter

  scope "/v2" do
    oci_routes(repo: ":org/:team/:image")
  end
end

defmodule NamespaceName.Endpoint do
  use Phoenix.Endpoint, otp_app: :oci

  plug(NamespaceNameRouter)
end

defmodule OrgTeamImage.Endpoint do
  use Phoenix.Endpoint, otp_app: :oci

  plug(OrgTeamImageRouter)
end

defmodule Conformance do
  def clone_repo!(repo) do
    path = conformance_dir()

    if File.exists?(path) do
      :ok
    else
      {output, status} =
        System.cmd("git", [
          "clone",
          "--depth",
          "1",
          repo,
          path
        ])

      case status do
        0 -> :ok
        _ -> raise "Failed to clone distribution-spec: #{output}"
      end
    end
  end

  def build!() do
    path = conformance_bin_path()

    if File.exists?(path) do
      :ok
    else
      dir = Path.dirname(path)
      {output, status} = System.cmd("go", ["test", "-c"], cd: dir, stderr_to_stdout: true)

      case status do
        0 ->
          :ok

        _ ->
          raise "Failed to build conformance test: #{output}"
      end
    end
  end

  def report!() do
    env = [
      {"OCI_ROOT_URL", "http://localhost:4002"},
      {"OCI_NAMESPACE", "myorg/myrepo"},
      {"OCI_CROSSMOUNT_NAMESPACE", "myorg/other"},
      {"OCI_USERNAME", "myuser"},
      {"OCI_PASSWORD", "mypass"},
      {"OCI_TEST_PULL", "1"},
      {"OCI_TEST_PUSH", "1"},
      {"OCI_TEST_CONTENT_DISCOVERY", "0"},
      {"OCI_TEST_CONTENT_MANAGEMENT", "0"},
      {"OCI_HIDE_SKIPPED_WORKFLOWS", "0"},
      {"OCI_DEBUG", "0"},
      {"OCI_DELETE_MANIFEST_BEFORE_BLOBS", "0"},
      {"OCI_AUTOMATIC_CROSSMOUNT", "1"},
      {"OCI_REPORT_DIR", conformance_report_dir()}
    ]

    {output, status} =
      System.cmd(
        conformance_bin_path(),
        [
          "--ginkgo.json-report",
          conformance_json_report_path()
        ],
        env: env,
        stderr_to_stdout: true
      )
  end

  def failures() do
    conformance_json_report_path()
    |> File.read!()
    |> Jason.decode!()
    |> List.first()
    |> Map.get("SpecReports")
    |> Enum.filter(fn test -> test["State"] == "failed" end)
    |> Enum.sort_by(fn test ->
      file_path = test["Failure"]["Location"]["FileName"]
      line_no = test["Failure"]["Location"]["LineNumber"]

      {file_path, line_no}
    end)
  end

  def conformance_dir() do
    ".tmp/oci-conformance"
  end

  def conformance_report_dir() do
    "#{conformance_dir()}/reports"
  end

  def conformance_json_report_path() do
    "#{conformance_report_dir()}/report.json"
  end

  def conformance_bin_path() do
    Path.expand("#{conformance_dir()}/distribution-spec/conformance/conformance.test")
  end
end

Application.put_env(:oci, NamespaceName.Endpoint,
  http: [port: 4002],
  server: true
)

{:ok, _} = Application.ensure_all_started(:oci)
{:ok, _pid} = NamespaceName.Endpoint.start_link()

IO.puts("✅ Phoenix endpoint started for conformance tests")

Conformance.clone_repo!("https://github.com/opencontainers/distribution-spec.git")
Conformance.build!()
Conformance.report!()

# TODO: remove this and the sorting above, doing this to make it easier to work through
# rework plug tests to focus on registry features / config
ExUnit.configure(seed: 0)
ExUnit.start()
