defmodule OCI.Pagination do
  @moduledoc """
  Provides pagination functionality for OCI registry operations, particularly for listing tags.

  This module handles the pagination parameters and results for operations that return
  large sets of data, such as listing repository tags. It supports the OCI Distribution
  Specification's pagination model using `n` (number of results) and `last` (last seen value)
  parameters.
  """
  use TypedStruct

  typedstruct do
    field :n, pos_integer(), enforce: false
    field :last, String.t(), enforce: false
  end
end
