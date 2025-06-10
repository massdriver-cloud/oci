defmodule OCI.Context do
  @moduledoc """
  Context for OCI requests.

  This module is responsible for storing the context of an OCI request.
  """

  use TypedStruct

  typedstruct do
    field(:repo, String.t())
    field(:subject, any())
    field(:method, String.t())
    field(:endpoint, atom())
    field(:resource, String.t())
  end
end
