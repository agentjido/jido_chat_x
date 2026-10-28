defmodule Jido.Chat.X do
  @moduledoc "X/Twitter Direct Messages adapter package for `Jido.Chat`."

  alias Jido.Chat.X.Adapter

  @doc "Returns the canonical X adapter module."
  def adapter, do: Adapter

  @doc "Returns provider-specific request and Action pairs."
  def operations, do: []

  @doc "Returns the incoming facts normalized by X."
  def event_definitions do
    [Jido.Chat.Signal.MessageReceived, Jido.Chat.Signal.NormalizationFailed]
  end
end
