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

defmodule TestRegistryWeb.Router do
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

defmodule TestRegistryWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :oci

  plug(TestRegistryWeb.Router)
end

# TODO:
# Either add tests for other route formats or see if we can get scope "/v2" to just forward to the plug
# without the macro. Seems very extra to me.
#
# defmodule OrgTeamImageRouter do
#   @moduledoc """
#   Test router simulating a registry with `:org/:team/:image` repo structure.

#   Example matching path:
#     /v2/acme/payments/api/tags/list
#   """
#   use Phoenix.Router
#   import OCI.PhoenixRouter

#   scope "/v2" do
#     oci_routes(repo: ":org/:team/:image")
#   end
# end

# defmodule OrgTeamImage.Endpoint do
#   use Phoenix.Endpoint, otp_app: :oci

#   plug(OrgTeamImageRouter)
# end
