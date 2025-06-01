defmodule OCI.Context do
  use TypedStruct

  typedstruct do
    field :repo, String.t()
    field :subject, String.t()
    field :action, atom()
    field :resource, String.t()
  end
end
