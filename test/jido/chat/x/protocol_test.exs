defmodule Jido.Chat.X.ProtocolTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.FileUpload
  alias Jido.Signal.Catalog
  alias Jido.Signal.Context
  alias Jido.Signal.Serialization
  alias Jido.Signal.Trace

  alias Jido.Chat.AdapterTestKit.Factories
  alias Jido.Chat.WebhookRequest
  alias Jido.Chat.X.Adapter

  defmodule Transport do
    @behaviour Jido.Chat.X.Transport
    @methods [
      send_dm: 3,
      send_conversation_message: 3,
      delete_dm_event: 2,
      fetch_dm_event: 2,
      fetch_conversation_messages: 2
    ]
    for {name, arity} <- @methods do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)) do
        send(self(), {:provider, unquote(name), [unquote_splicing(args)]})
        if Process.get(:provider_failure), do: {:error, :timeout}, else: result(unquote(name))
      end
    end

    defp event,
      do: %{"id" => "m1", "sender_id" => "u1", "text" => "body", "dm_conversation_id" => "C1"}

    defp result(:delete_dm_event), do: :ok
    defp result(:fetch_dm_event), do: {:ok, %{"data" => event()}}

    defp result(:fetch_conversation_messages),
      do:
        {:ok,
         %{"data" => [event(), Map.put(event(), "id", "m2")], "meta" => %{"next_token" => "next"}}}

    defp result(_), do: {:ok, %{"data" => %{"dm_event_id" => "m1", "dm_conversation_id" => "C1"}}}
  end

  @matrix Path.join(Mix.Project.deps_paths()[:jido_chat], "docs/migration/adapter-matrix.json")
          |> File.read!()
          |> Jason.decode!()
  @row Enum.find(@matrix["adapters"], &(&1["package"] == "jido_chat_x"))
  @calls %{
    send_message: [:send_dm],
    send_file: [:send_dm],
    post_message: [:send_dm],
    delete_message: [:delete_dm_event],
    fetch_message: [:fetch_dm_event],
    fetch_messages: [:fetch_conversation_messages],
    post_channel_message: [:send_dm],
    stream: [:send_dm]
  }
  setup do
    {:ok, binding} =
      Jido.Chat.bind(Adapter,
        id: "x-contract",
        transport: Transport,
        consumer_secret: "private-token",
        xdk_client: :private_client
      )

    %{binding: binding}
  end

  defp request(binding, operation, extra \\ %{}) do
    extra =
      if operation == :send_file do
        {:ok, ref} =
          Jido.Chat.put_resource(
            binding,
            "file",
            FileUpload.new(%{url: "https://fixture.test/file", filename: "file.txt"})
          )

        Map.put(extra, "resource_ref", ref)
      else
        extra
      end

    Factories.operation_request(binding, operation, extra)
  end

  defp calls do
    receive do
      {:provider, name, _} -> [name | calls()]
    after
      0 -> []
    end
  end

  defp portable(fact) do
    {:ok, json} = Serialization.serialize(fact)

    assert {:ok, ^fact} =
             Catalog.decode(
               Catalog.new!(Jido.Chat.signal_definitions()),
               json
             )

    refute json =~ "private-token"
    refute json =~ "private_client"
    refute json =~ "\"raw\":"
  end

  for {name, support} <- @row["operation_support"] do
    operation = String.to_atom(name)

    test "#{name} matches frozen #{support} with exact calls and a cached native result", %{
      binding: binding
    } do
      operation = unquote(operation)

      assert Jido.Chat.Adapter.capabilities(Adapter)[operation] ==
               unquote(String.to_atom(support))

      parent = request(binding, operation)
      before = Jido.Signal.to_map(parent)
      assert {:ok, result} = Jido.Chat.execute(binding, parent)

      if unquote(support) == "unsupported" do
        assert result.type == "jido.chat.operation.failed" and
                 result.data["code"] == "unsupported"
      else
        assert result.type == "jido.chat.operation.completed"
      end

      assert calls() == unquote(Map.get(@calls, operation, []))
      assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
      assert calls() == []
      assert Jido.Signal.to_map(parent) == before
      assert Context.get(result, "causationid") == parent.id
      assert Trace.get(result).trace_id == Trace.get(parent).trace_id
      portable(result)
    end
  end

  defp event(id \\ "m1", text \\ "body") do
    %{
      "type" => "message_create",
      "id" => id,
      "message_create" => %{"sender_id" => "u1", "message_data" => %{"text" => text}}
    }
  end

  defp signed(events) do
    payload = %{"direct_message_events" => events}
    raw = Jason.encode!(payload)
    signature = "sha256=" <> Base.encode64(:crypto.mac(:hmac, :sha256, "private-token", raw))

    WebhookRequest.new(%{
      payload: payload,
      raw: raw,
      headers: %{"x-twitter-webhooks-signature" => signature}
    })
  end

  for {name, support} <- @row["event_support"] do
    test "#{name} matches frozen #{support} after verification", %{binding: binding} do
      input =
        if unquote(name) == "MessageReceived",
          do: event(),
          else: Map.put(event(), "type", unquote(name))

      assert {:ok, %{signals: [fact]} = unit} =
               Jido.Chat.normalize_event(binding, signed([input]))

      expected =
        if unquote(support) == "unsupported",
          do: "jido.chat.normalization.failed",
          else: Module.concat(Jido.Chat.Signal, unquote(name)).type()

      assert fact.type == expected

      assert {:ok, %{signals: [repeated]} = repeat_unit} =
               Jido.Chat.normalize_event(binding, signed([input]))

      assert unit.id == repeat_unit.id and fact.data["item_id"] == repeated.data["item_id"]
      portable(fact)
      assert calls() == []
    end
  end

  test "zero, one and every DM item keep their order and stable identity", %{binding: binding} do
    assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, signed([]))

    assert {:ok, %{signals: [one]}} =
             Jido.Chat.normalize_event(binding, signed([event("second")]))

    assert {:ok, %{signals: [first, second, last]}} =
             Jido.Chat.normalize_event(
               binding,
               signed([event("first"), event("second"), event("last")])
             )

    assert Enum.map([first, second, last], & &1.data["message_id"]) == ["first", "second", "last"]
    assert second.data["item_id"] == one.data["item_id"]
    {:ok, other} = Jido.Chat.bind(Adapter, id: "other", consumer_secret: "private-token")
    assert {:ok, other_unit} = Jido.Chat.normalize_event(other, signed([event("second")]))
    refute other_unit.id == one.data["delivery_id"]
  end

  test "a malformed DM is retained as a failure before the next valid DM", %{binding: binding} do
    malformed = Map.put(event(), "message_create", :invalid)

    assert {:ok, %{signals: [failed, valid]}} =
             Jido.Chat.normalize_event(binding, signed([malformed, event("good")]))

    assert failed.type == "jido.chat.normalization.failed" and valid.data["message_id"] == "good"
  end

  test "verification, all limits and sink rejection cannot produce an accepted HTTP control", %{
    binding: binding
  } do
    bad = %{signed([event()]) | headers: %{"x-twitter-webhooks-signature" => "invalid"}}
    assert {:error, error} = Jido.Chat.normalize_event(binding, bad)
    assert Adapter.format_webhook_response({:error, error}, []).status == 400
    assert :ets.tab2list(binding.resources) == []

    batches = [
      [event("big", String.duplicate("x", 262_145))],
      List.duplicate(event(), 101),
      List.duplicate(Map.put(event(), "type", "unknown"), 21),
      Enum.map(1..6, &event("#{&1}", String.duplicate("x", 200_000)))
    ]

    for batch <- batches do
      assert {:error, error} = Jido.Chat.normalize_event(binding, signed(batch))
      assert Adapter.format_webhook_response({:error, error}, []).status == 400
    end

    assert Adapter.format_webhook_response({:error, {:sink_rejected, "private-token"}}, []).status ==
             400

    refute inspect(Adapter.format_webhook_response({:error, "private-token"}, [])) =~
             "private-token"

    assert calls() == []
  end

  test "CRC responses stay private and binding secrets remain captured" do
    previous = System.get_env("X_CONSUMER_SECRET")

    on_exit(fn ->
      if previous,
        do: System.put_env("X_CONSUMER_SECRET", previous),
        else: System.delete_env("X_CONSUMER_SECRET")
    end)

    System.put_env("X_CONSUMER_SECRET", "private-token")
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "captured")
    System.put_env("X_CONSUMER_SECRET", "changed")

    request =
      WebhookRequest.new(%{method: "GET", query: %{"crc_token" => "challenge"}, payload: %{}})

    assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, request)

    assert Adapter.format_webhook_response(request, binding.options).body == %{
             "response_token" =>
               "sha256=" <>
                 Base.encode64(:crypto.mac(:hmac, :sha256, "private-token", "challenge"))
           }

    assert Adapter.format_webhook_response(%{request | query: %{}}, binding.options).status == 400
    assert Adapter.format_webhook_response(request, consumer_secret: nil).status == 400
  end

  test "history returns every item and cursor without private SDK state", %{binding: binding} do
    parent =
      request(binding, :fetch_messages, %{
        "room_id" => "conversation:C1",
        "cursor" => "before",
        "limit" => 2
      })

    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert Enum.map(result.data["result"]["messages"], & &1["id"]) == ["m1", "m2"]

    assert result.data["result"]["next_cursor"] == "next" and
             result.data["result"]["complete"] == false

    assert_receive {:provider, :fetch_conversation_messages, ["C1", opts]}
    assert opts[:cursor] == "before" and opts[:limit] == 2
    portable(result)
  end

  test "media ownership, expiry and cancellation stay private", %{binding: binding} do
    input =
      put_in(event(), ["message_create", "message_data", "attachment"], %{
        "type" => "media",
        "media" => %{"type" => "photo", "media_url_https" => "https://fixture.test/file.png"}
      })

    assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, signed([input]))
    [item] = fact.data["media"]
    ref = item["resource_ref"]
    assert {:ok, media} = Jido.Chat.resolve_resource(binding, ref)
    assert media.url == "https://fixture.test/file.png"

    assert {:error, %{code: :resource_owner_mismatch}} =
             Task.async(fn -> Jido.Chat.resolve_resource(binding, ref) end) |> Task.await()

    :ok = Jido.Chat.cancel_resource(binding, ref)
    assert {:error, %{code: :resource_cancelled}} = Jido.Chat.resolve_resource(binding, ref)
    {:ok, expired} = Jido.Chat.put_resource(binding, "media", media, ttl_ms: 0)
    assert {:error, %{code: :resource_expired}} = Jido.Chat.resolve_resource(binding, expired)
    portable(fact)
  end

  test "provider failure is typed and cached with one call", %{binding: binding} do
    Process.put(:provider_failure, true)
    parent = request(binding, :send_message)
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["code"] == "provider_failure"
    assert calls() == [:send_dm]
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    assert calls() == []
  end

  test "cancelled stream has zero enumeration and provider calls", %{binding: binding} do
    stream =
      Stream.map(["hello"], fn text ->
        send(self(), :enumerated)
        text
      end)

    {:ok, ref} = Jido.Chat.put_resource(binding, "stream", stream)
    :ok = Jido.Chat.cancel_resource(binding, ref)
    parent = request(binding, :stream, %{"resource_ref" => ref})
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["code"] == "resource_cancelled"
    refute_received :enumerated
    assert calls() == []
  end

  test "HTTP mapping uses the signed body and a POST request cannot bypass acceptance", %{
    binding: binding
  } do
    signed = signed([event("signed", "signed text")])

    request = %{
      signed
      | payload: %{"direct_message_events" => [event("unsigned", "unsigned text")]}
    }

    assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, request)
    assert fact.data["message_id"] == "signed" and fact.data["text"] == "signed text"
    assert Adapter.format_webhook_response(request, binding.options).status == 400
  end
end
