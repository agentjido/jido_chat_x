defmodule Jido.Chat.X.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Handlers

  alias Jido.Chat
  alias Jido.Chat.Adapter, as: ChatAdapter
  alias Jido.Chat.{PostPayload, WebhookRequest, WebhookResponse}
  alias Jido.Chat.X.Adapter

  defmodule FakeTransport do
    @behaviour Jido.Chat.X.Transport

    def send_dm("123", text, _opts) do
      send(self(), {:x_send_dm, "123", text})

      {:ok,
       %{
         "data" => %{
           "dm_conversation_id" => "123-999",
           "dm_event_id" => "evt1",
           "text" => text
         }
       }}
    end

    def send_conversation_message("123-999", text, _opts) do
      send(self(), {:x_send_conversation_message, "123-999", text})

      {:ok,
       %{
         "data" => %{
           "dm_conversation_id" => "123-999",
           "dm_event_id" => "evt2",
           "text" => text
         }
       }}
    end

    def delete_dm_event(_event_id, _opts), do: :ok

    def fetch_dm_event("evt1", _opts),
      do:
        {:ok,
         %{
           "data" => %{
             "id" => "evt1",
             "text" => "hello",
             "sender_id" => "123",
             "dm_conversation_id" => "123-999"
           }
         }}

    def fetch_conversation_messages(_conversation_id, _opts),
      do:
        {:ok,
         %{
           "data" => [
             %{
               "id" => "evt1",
               "text" => "hello",
               "sender_id" => "123",
               "dm_conversation_id" => "123-999"
             }
           ]
         }}
  end

  test "declares a valid capability matrix" do
    assert :ok = ChatAdapter.validate_capabilities(Adapter)
  end

  test "sends a one-to-one DM and a conversation DM" do
    assert {:ok, response} = Adapter.send_message("123", "hello", transport: FakeTransport)
    assert response.external_message_id == "evt1"
    assert response.external_room_id == "conversation:123-999"
    assert_received {:x_send_dm, "123", "hello"}

    assert {:ok, response} =
             Adapter.send_message("conversation:123-999", "hello", transport: FakeTransport)

    assert response.external_message_id == "evt2"
    assert response.external_room_id == "conversation:123-999"
    assert_received {:x_send_conversation_message, "123-999", "hello"}
  end

  test "posts rich payloads and remote file links as text" do
    payload =
      PostPayload.new(%{
        kind: :markdown,
        markdown: "**hello**",
        files: [
          %{kind: :image, url: "https://example.test/image.png", filename: "image.png"},
          %{kind: :file, url: "https://example.test/report.pdf", filename: "report.pdf"}
        ]
      })

    assert {:ok, response} =
             Adapter.post_message("conversation:123-999", payload,
               transport: FakeTransport,
               reply_to_id: "evt0"
             )

    assert response.external_message_id == "evt2"
    assert %{attachments: [_image, _file]} = response.metadata

    assert_received {:x_send_conversation_message, "123-999", body}
    assert body =~ "Replying to evt0:"
    assert body =~ "**hello**"
    assert body =~ "image.png: https://example.test/image.png"
    assert body =~ "report.pdf: https://example.test/report.pdf"

    assert {:ok, _response} =
             Adapter.send_file(
               "conversation:123-999",
               %{url: "https://example.test/report.pdf", filename: "report.pdf"},
               transport: FakeTransport,
               caption: "See report"
             )

    assert_received {:x_send_conversation_message, "123-999", file_body}
    assert file_body =~ "See report"
    assert file_body =~ "report.pdf: https://example.test/report.pdf"

    assert {:error, {:unsupported_file_upload, :x_requires_media_upload_or_remote_url}} =
             Adapter.send_file("conversation:123-999", %{path: "/tmp/report.pdf"},
               transport: FakeTransport
             )
  end

  test "fetches direct message history and individual messages" do
    assert {:ok, page} = Adapter.fetch_messages("conversation:123-999", transport: FakeTransport)
    assert [message] = page.messages
    assert message.external_message_id == "evt1"
    assert message.text == "hello"

    assert {:ok, fetched} =
             Adapter.fetch_message("conversation:123-999", "evt1", transport: FakeTransport)

    assert fetched.external_message_id == "evt1"
    assert fetched.text == "hello"
  end

  test "opens a user id as a DM room" do
    assert {:ok, "123"} = Adapter.open_dm(123)
  end

  test "normalizes account activity DM webhook events with media" do
    event = account_activity_event()

    incoming = normalize(%{"dm_event" => event})
    assert incoming.data["room_id"] == "conversation:123"
    assert incoming.data["sender"]["id"] == "123"
    assert incoming.data["text"] == "hello"
    assert [media] = media(incoming)
    assert media.kind == :image
    assert media.url == "https://example.test/photo.jpg"
    assert media.media_type == "image/jpeg"

    explicit =
      put_in(
        event,
        ["message_create", "message_data", "attachment", "media", "mime_type"],
        "image/png"
      )

    explicit_incoming = normalize(%{"dm_event" => explicit})
    assert [%{media_type: "image/png"}] = media(explicit_incoming)

    invalid_explicit =
      event
      |> put_in(
        ["message_create", "message_data", "attachment", "media", "mime_type"],
        "not-a-mime"
      )
      |> put_in(
        ["message_create", "message_data", "attachment", "media", "url"],
        " "
      )
      |> put_in(
        ["message_create", "message_data", "attachment", "media", "media_url_https"],
        "https://example.test/photo.PNG?token=signed"
      )

    invalid_incoming = normalize(%{"dm_event" => invalid_explicit})

    assert [%{kind: :image, media_type: "image/png"}] = media(invalid_incoming)

    misleading =
      put_in(
        event,
        ["message_create", "message_data", "attachment", "media", "media_url_https"],
        "https://example.test/report.pdf"
      )

    misleading_incoming = normalize(%{"dm_event" => misleading})
    assert [%{kind: :image, media_type: nil}] = media(misleading_incoming)
  end

  test "normalizes X API v2 DM events with included media" do
    payload = v2_payload()

    envelope = normalize(payload)
    assert envelope.type == "jido.chat.message.received"

    assert envelope.data["room_id"] == "conversation:abc" and
             envelope.data["text"] == "hello with media"

    assert [%{kind: :image, url: "https://example.test/preview.jpg", media_type: nil}] =
             media(envelope)
  end

  test "verifies POST webhook signatures against the raw body" do
    secret = "x-secret"
    payload = %{"direct_message_events" => [account_activity_event()]}
    raw = Jason.encode!(payload)

    request =
      WebhookRequest.new(%{
        method: "POST",
        headers: %{"x-twitter-webhooks-signature" => x_signature(secret, raw)},
        payload: payload,
        raw: raw
      })

    assert :ok = Adapter.verify_webhook(request, consumer_secret: secret)
    assert {:error, :invalid_signature} = Adapter.verify_webhook(request, consumer_secret: "bad")
  end

  test "formats CRC webhook responses" do
    request =
      WebhookRequest.new(%{
        method: "GET",
        query: %{"crc_token" => "challenge"},
        payload: %{}
      })

    assert :ok = Adapter.verify_webhook(request, consumer_secret: "x-secret")

    assert %WebhookResponse{status: 200, body: %{"response_token" => response_token}} =
             Adapter.format_webhook_response(request, consumer_secret: "x-secret")

    assert response_token == "sha256=" <> x_hmac("x-secret", "challenge")
  end

  test "routes signed X webhooks through handle_webhook/3" do
    payload = %{"direct_message_events" => [account_activity_event()]}
    raw = Jason.encode!(payload)
    secret = "x-secret"

    {:ok, binding} = Chat.bind(Adapter, id: "x-route", consumer_secret: secret)

    request =
      WebhookRequest.new(%{
        payload: payload,
        raw: raw,
        headers: %{"x-twitter-webhooks-signature" => x_signature(secret, raw)}
      })

    assert {:ok, unit} = Chat.normalize_event(binding, request)
    {:ok, handlers} = Handlers.new()

    {:ok, handlers} =
      Handlers.on(handlers, Jido.Chat.Signal.MessageReceived, fn fact ->
        send(self(), {:x_message, fact})
      end)

    assert {:ok, _, _} = Handlers.accept(handlers, binding, unit)
    assert [incoming] = unit.signals

    assert incoming.data["room_id"] == "conversation:123" and
             incoming.data["message_id"] == "evt1"

    assert_received {:x_message, ^incoming}
    refute_received {:x_message, _}
  end

  defp normalize(payload) do
    {:ok, binding} = Chat.bind(Adapter, id: "x-test")
    Process.put(:x_binding, binding)
    assert {:ok, %{signals: [fact]}} = Chat.normalize_event(binding, payload)
    fact
  end

  defp media(fact) do
    Enum.map(fact.data["media"], fn item ->
      assert {:ok, media} = Chat.resolve_resource(Process.get(:x_binding), item["resource_ref"])
      media
    end)
  end

  defp account_activity_event do
    %{
      "type" => "message_create",
      "id" => "evt1",
      "created_timestamp" => "1777237605160",
      "message_create" => %{
        "sender_id" => "123",
        "message_data" => %{
          "text" => "hello",
          "attachment" => %{
            "type" => "media",
            "media" => %{
              "id" => "m1",
              "type" => "photo",
              "media_url_https" => "https://example.test/photo.jpg"
            }
          }
        }
      }
    }
  end

  defp v2_payload do
    %{
      "data" => [
        %{
          "id" => "evt2",
          "dm_conversation_id" => "abc",
          "sender_id" => "123",
          "text" => "hello with media",
          "attachments" => %{"media_keys" => ["3_1"]}
        }
      ],
      "includes" => %{
        "media" => [
          %{
            "media_key" => "3_1",
            "type" => "photo",
            "preview_image_url" => "https://example.test/preview.jpg"
          }
        ]
      }
    }
  end

  defp x_signature(secret, raw), do: "sha256=" <> x_hmac(secret, raw)
  defp x_hmac(secret, raw), do: :crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode64()
end
