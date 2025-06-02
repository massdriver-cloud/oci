defmodule OCI.Context do
  use TypedStruct

  typedstruct do
    field :repo, String.t()
    field :subject, String.t()
    field :method, String.t()
    field :endpoint, atom()
    field :resource, String.t()
  end
end
