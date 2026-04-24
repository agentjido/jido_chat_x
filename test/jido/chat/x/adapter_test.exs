defmodule Jido.Chat.X.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.X.Adapter

  defmodule FakeTransport do
    @behaviour Jido.Chat.X.Transport

    def send_dm("123", "hello", _opts),
      do: {:ok, %{"data" => %{"dm_conversation_id" => "123-999", "dm_event_id" => "evt1"}}}

    def send_conversation_message("123-999", "hello", _opts),
      do: {:ok, %{"data" => %{"dm_conversation_id" => "123-999", "dm_event_id" => "evt2"}}}

    def delete_dm_event(_, _opts), do: :ok

    def fetch_conversation_messages(_, _opts),
      do: {:ok, %{"data" => [%{"id" => "evt1", "text" => "hello", "sender_id" => "123"}]}}
  end

  test "sends a one-to-one DM" do
    assert {:ok, response} = Adapter.send_message("123", "hello", transport: FakeTransport)
    assert response.external_message_id == "evt1"
    assert response.external_room_id == "conversation:123-999"
  end

  test "normalizes DM webhook event" do
    event = %{
      "id" => "evt1",
      "dm_conversation_id" => "123-999",
      "sender_id" => "123",
      "text" => "hello"
    }

    assert {:ok, incoming} = Adapter.transform_incoming(%{"dm_event" => event})
    assert incoming.external_room_id == "conversation:123-999"
    assert incoming.text == "hello"
  end
end
