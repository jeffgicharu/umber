defmodule Umber.Notify.Subscription do
  use Umber.Schema

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    belongs_to :user, Umber.Accounts.User
    timestamps()
  end
end

defmodule Umber.Notify do
  @moduledoc """
  Notices on the bidder's phone or computer when Umber is not open: outbid,
  won, and a watched lot about to close. Web Push, with our own VAPID keys
  and the message encrypted for the browser as RFC 8291 describes, using only
  Erlang's crypto and HTTP client. No third-party account is involved.
  """

  import Ecto.Query
  alias Umber.Repo
  alias Umber.Notify.Subscription

  def public_key, do: Application.get_env(:umber, :vapid)[:public_key]
  def enabled?, do: not is_nil(Application.get_env(:umber, :vapid))

  def subscribe(user, %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}})
      when is_binary(endpoint) and byte_size(endpoint) < 1000 do
    if String.starts_with?(endpoint, "https://") do
      Repo.insert(%Subscription{user_id: user.id, endpoint: endpoint, p256dh: p256dh, auth: auth},
        on_conflict: [
          set: [user_id: user.id, p256dh: p256dh, auth: auth, updated_at: DateTime.utc_now()]
        ],
        conflict_target: :endpoint
      )
    else
      {:error, :bad_endpoint}
    end
  end

  def subscribe(_, _), do: {:error, :bad_subscription}

  def unsubscribe(user, endpoint) do
    from(s in Subscription, where: s.user_id == ^user.id and s.endpoint == ^endpoint)
    |> Repo.delete_all()

    :ok
  end

  def subscribed?(user_id), do: Repo.exists?(from s in Subscription, where: s.user_id == ^user_id)

  @doc "Queues a notice for a bidder's devices, if they turned notifications on."
  def push(user_id, notice) do
    if enabled?() and subscribed?(user_id) do
      %{
        user_id: user_id,
        title: title(notice),
        body: body(notice),
        url: notice.path,
        tag: "lot-#{notice.lot_id}"
      }
      |> Umber.Notify.Worker.new()
      |> Oban.insert()
    end

    :ok
  end

  defp title(%{kind: "outbid", amount: a}), do: "Outbid at #{Umber.Format.money(a)}"
  defp title(%{kind: "won", amount: a}), do: "You won, at #{Umber.Format.money(a)}"
  defp title(%{kind: "closing"}), do: "Five minutes left"
  defp title(_), do: "Umber"

  defp body(n), do: "Lot #{n.lot_number}, #{n.title}."

  ## Sending

  @doc "Encrypts and sends one message to one subscription."
  def send_push(%Subscription{} = sub, payload) when is_binary(payload) do
    body = encrypt(payload, decode64(sub.p256dh), decode64(sub.auth))
    %URI{scheme: scheme, host: host, port: port} = URI.parse(sub.endpoint)
    audience = "#{scheme}://#{host}#{if port in [80, 443, nil], do: "", else: ":#{port}"}"

    headers = [
      {~c"authorization",
       String.to_charlist("vapid t=#{vapid_jwt(audience)}, k=#{public_key()}")},
      {~c"content-encoding", ~c"aes128gcm"},
      {~c"ttl", ~c"300"},
      {~c"urgency", ~c"high"}
    ]

    request = {String.to_charlist(sub.endpoint), headers, ~c"application/octet-stream", body}

    case :httpc.request(:post, request, [timeout: 10_000, ssl: ssl_options()], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      # The browser dropped the subscription; forget it.
      {:ok, {{_, status, _}, _, _}} when status in [404, 410] -> Repo.delete(sub) && :gone
      {:ok, {{_, status, _}, _, resp}} -> {:error, {status, to_string(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  @doc false
  # RFC 8291: one aes128gcm record for the browser's key and auth secret.
  def encrypt(plaintext, ua_public, auth_secret) do
    {as_public, as_private} = :crypto.generate_key(:ecdh, :prime256v1)
    shared = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)

    prk_key = hmac(auth_secret, shared)
    ikm = hmac(prk_key, "WebPush: info" <> <<0>> <> ua_public <> as_public <> <<1>>)

    salt = :crypto.strong_rand_bytes(16)
    prk = hmac(salt, ikm)
    <<cek::binary-size(16), _::binary>> = hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
    <<nonce::binary-size(12), _::binary>> = hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>)

    # The record ends with the delimiter 0x02: this is the last record.
    {cipher, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, <<>>, true)

    <<salt::binary, 4096::unsigned-big-32, byte_size(as_public)::8, as_public::binary,
      cipher::binary, tag::binary>>
  end

  defp vapid_jwt(audience) do
    vapid = Application.fetch_env!(:umber, :vapid)
    header = b64(Jason.encode!(%{typ: "JWT", alg: "ES256"}))

    claims =
      b64(
        Jason.encode!(%{
          aud: audience,
          exp: System.system_time(:second) + 12 * 3600,
          sub: vapid[:subject]
        })
      )

    signing_input = header <> "." <> claims

    der =
      :crypto.sign(:ecdsa, :sha256, signing_input, [decode64(vapid[:private_key]), :prime256v1])

    signing_input <> "." <> b64(der_to_raw(der))
  end

  # ES256 in a JWT is the raw 64-byte r || s, not the DER Erlang returns.
  defp der_to_raw(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::unsigned-big-256, s::unsigned-big-256>>
  end

  @doc "A new VAPID key pair as settings lines; written straight into the settings file, never shown."
  def generate_env_lines do
    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)
    "VAPID_PUBLIC_KEY=#{b64(pub)}\nVAPID_PRIVATE_KEY=#{b64(priv)}\n"
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp b64(bin), do: Base.url_encode64(bin, padding: false)
  defp decode64(s), do: Base.url_decode64!(s, padding: false)
end

defmodule Umber.Notify.Worker do
  @moduledoc "Sends one notice to every device a bidder turned notifications on for."
  use Oban.Worker, queue: :push, max_attempts: 3

  import Ecto.Query
  alias Umber.{Repo, Notify}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => uid} = args}) do
    payload = Jason.encode!(Map.take(args, ~w(title body url tag)))

    from(s in Notify.Subscription, where: s.user_id == ^uid)
    |> Repo.all()
    |> Enum.each(&Notify.send_push(&1, payload))

    :ok
  end
end
