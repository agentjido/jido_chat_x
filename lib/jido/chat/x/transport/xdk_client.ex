defmodule Jido.Chat.X.Transport.XdkClient do
  @moduledoc "XDK-backed transport for X Direct Messages."
  @behaviour Jido.Chat.X.Transport

  @impl true
  def send_dm(participant_id, text, opts) do
    client = client!(opts)
    Xdk.DirectMessages.create_by_participant_id(client, participant_id, %{"text" => text})
  rescue
    UndefinedFunctionError ->
      {:error, :xdk_dm_endpoint_missing}
  end

  @impl true
  def send_conversation_message(conversation_id, text, opts) do
    client = client!(opts)
    Xdk.DirectMessages.create_by_conversation_id(client, conversation_id, %{"text" => text})
  rescue
    UndefinedFunctionError ->
      {:error, :xdk_dm_endpoint_missing}
  end

  @impl true
  def delete_dm_event(event_id, opts) do
    client = client!(opts)

    case Xdk.DirectMessages.delete_events(client, event_id) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  rescue
    UndefinedFunctionError ->
      {:error, :xdk_dm_endpoint_missing}
  end

  @impl true
  def fetch_conversation_messages(conversation_id, opts) do
    client = client!(opts)
    Xdk.DirectMessages.get_events_by_conversation_id(client, conversation_id, opts)
  rescue
    UndefinedFunctionError ->
      {:error, :xdk_dm_endpoint_missing}
  end

  defp client!(opts) do
    Keyword.get(opts, :xdk_client) ||
      Keyword.get(opts, :client) ||
      raise ArgumentError, "missing :xdk_client option for X adapter transport"
  end
end
