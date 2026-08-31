defmodule Voxgig.Plugin.Error do
  @moduledoc """
  Every error carries a section 12 code. Ports compare by CODE and never by
  message: wording is a port's own business, and pinning the words would
  make every translation a corpus change. The FORMAT, however, is pinned -
  a parseable message is what makes a log searchable across twenty
  languages.
  """
  defexception [:code, :text, :details, :message]
end
