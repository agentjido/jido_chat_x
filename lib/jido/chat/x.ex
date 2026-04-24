defmodule Jido.Chat.X do
  @moduledoc "X/Twitter Direct Messages adapter package for `Jido.Chat`."

  alias Jido.Chat.X.Adapter

  @doc "Returns the canonical X adapter module."
  def adapter, do: Adapter
end
