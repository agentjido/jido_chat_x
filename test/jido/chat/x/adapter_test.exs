defmodule Jido.Chat.X.AdapterTest do
  use Jido.Chat.AdapterTestKit, adapter: Jido.Chat.X.Adapter

  alias Jido.Chat.Client
  alias Jido.Chat.Signal.{FetchMessages, Policy}
  alias Jido.Chat.X.Adapter

  defmodule FakeTransport do
    @behaviour Jido.Chat.X.Transport

    @impl true
    def send_dm(participant_id, text, _opts) do
      send(self(), {:send_dm, participant_id, text})
      {:ok, %{"data" => %{"dm_event_id" => "m1", "dm_conversation_id" => "c1", "text" => text}}}
    end

    @impl true
    def send_conversation_message(conversation_id, text, _opts) do
      send(self(), {:send_conversation_message, conversation_id, text})

      {:ok,
       %{
         "data" => %{
           "dm_event_id" => "m2",
           "dm_conversation_id" => conversation_id,
           "text" => text
         }
       }}
    end

    @impl true
    def delete_dm_event(id, _opts) do
      send(self(), {:delete, id})
      :ok
    end

    @impl true
    def fetch_dm_event(id, _opts),
      do: {:ok, %{"data" => event(id)}}

    @impl true
    def fetch_conversation_messages(_id, _opts),
      do: {:ok, %{"data" => [event("m1"), event("m2")], "meta" => %{"next_token" => "next"}}}

    defp event(id),
      do: %{"id" => id, "sender_id" => "u1", "text" => "hello", "dm_conversation_id" => "c1"}
  end

  setup do
    client = Client.new!(Adapter, id: "x-test", transport: FakeTransport)
    %{client: client}
  end

  test "executes the native message lifecycle through public Chat Actions", %{client: client} do
    assert {:ok, sent} = Jido.Chat.send_text(client, "u1", "hello")
    assert sent.data["result"]["id"] == "m1"

    assert {:ok, request} =
             Policy.new(FetchMessages, %{
               "client_id" => client.id,
               "request_id" => "x:history",
               "room_id" => "conversation:c1"
             })

    assert {:ok, page} = Jido.Chat.execute(client, request)
    assert Enum.map(page.data["result"]["messages"], & &1["id"]) == ["m1", "m2"]
    assert page.data["result"]["next_cursor"] == "next"

    assert {:ok, deleted} = Jido.Chat.delete_message(client, "conversation:c1", "m1")
    assert deleted.data["result"] == %{"acknowledged" => true}
  end

  test "normalizes direct message events with stable identities", %{client: client} do
    payload = %{
      "direct_message_events" => [
        %{
          "type" => "message_create",
          "id" => "m1",
          "dm_conversation_id" => "c1",
          "message_create" => %{"sender_id" => "u1", "message_data" => %{"text" => "hello"}}
        }
      ]
    }

    assert {:ok, first} = Jido.Chat.normalize(client, payload)
    assert {:ok, second} = Jido.Chat.normalize(client, payload)
    assert [signal] = first.signals
    assert signal.type == "jido.chat.message.received"
    assert signal.data["room_id"] == "conversation:c1"
    assert first.id == second.id
    assert signal.data["item_id"] == hd(second.signals).data["item_id"]
  end

  test "retains unsupported provider events as normalization failures", %{client: client} do
    assert {:ok, delivery} = Jido.Chat.normalize(client, %{"type" => "unknown", "id" => "e1"})
    assert [failed] = delivery.signals
    assert failed.type == "jido.chat.normalization.failed"
    assert failed.data["code"] == "unsupported_item"
  end
end
