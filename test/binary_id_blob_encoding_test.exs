defmodule EctoLibSql.BinaryIdBlobEncodingTest do
  @moduledoc """
  Binary ids must be stored as BLOB, whatever their bytes happen to spell.

  Untagged, a binary id reaches the NIF as a bare Elixir binary and the
  argument conversion there tries `decode::<String>()` before
  `decode::<Binary>()`. A UUID whose 16 bytes are valid UTF-8 therefore lands
  as TEXT, and the damage is mostly silent: such a row is not found by a
  blob-typed lookup, so another client reading the same file cannot see it. If
  those bytes also contain a NUL, reading the value back truncates it there,
  which is how this was noticed — `cannot load <<...>> as type Ash.Type.UUID`
  with 0, 4 or 15 of the expected 16 bytes.

  **These fixtures are deterministic on purpose.** Only ~1 in 16,000 random v4
  UUIDs is valid UTF-8, so a property test over generated ids would pass
  15,999 times out of 16,000 and prove nothing. Every id below is chosen to sit
  on the failing side.
  """
  use ExUnit.Case, async: true

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule Thing do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "things" do
      field(:payload, :binary)
      field(:label, :string)
    end
  end

  @test_db "/tmp/ecto_libsql_binary_id_test.db"

  # The real one. Found in a production database during the investigation that
  # produced this fix: 16 bytes, valid UTF-8 (D4 9F and CB 8B are two-byte
  # sequences, so SQLite reported length() as 14), no NUL — the silent variant,
  # stored as TEXT and never noticed. Kept as a fixture because it is the
  # realest possible case and costs nothing to carry.
  @production_row_id Base.decode16!("24D49F202B5F42CB8B153B032C474830")

  # Valid UTF-8 and NUL-bearing: these truncate on read when stored as TEXT.
  # The NUL position dictates the surviving length, which is why the reported
  # sightings were 0, 4 and 15 bytes.
  @nul_at_1 <<0, ?A, ?B, ?C, ?D, ?E, ?F, ?G, ?H, ?I, ?J, ?K, ?L, ?M, ?N, ?O>>
  @nul_at_5 <<?A, ?B, ?C, ?D, 0, ?E, ?F, ?G, ?H, ?I, ?J, ?K, ?L, ?M, ?N, ?O>>
  @nul_at_16 <<?A, ?B, ?C, ?D, ?E, ?F, ?G, ?H, ?I, ?J, ?K, ?L, ?M, ?N, ?O, 0>>

  # Valid UTF-8, no NUL: stored as TEXT it round-trips whole, so nothing looks
  # wrong — but the row is filed under the wrong storage class.
  @utf8_no_nul <<?A, ?B, ?C, ?D, ?E, ?F, ?G, ?H, ?I, ?J, ?K, ?L, ?M, ?N, ?O, ?P>>

  setup_all do
    File.rm(@test_db)
    {:ok, _} = TestRepo.start_link(database: @test_db)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "CREATE TABLE things (id BLOB PRIMARY KEY, payload BLOB, label TEXT)",
      []
    )

    on_exit(fn -> File.rm(@test_db) end)
    :ok
  end

  defp typeof(id) do
    %{rows: [[t]]} =
      Ecto.Adapters.SQL.query!(TestRepo, "SELECT typeof(id) FROM things WHERE id = ?1", [
        {:blob, id}
      ])

    t
  end

  defp stored_hex(id) do
    %{rows: [[h]]} =
      Ecto.Adapters.SQL.query!(TestRepo, "SELECT hex(id) FROM things WHERE id = ?1", [{:blob, id}])

    h
  end

  for {name, id} <- [
        production_row: @production_row_id,
        utf8_no_nul: @utf8_no_nul,
        nul_at_byte_1: @nul_at_1,
        nul_at_byte_5: @nul_at_5,
        nul_at_byte_16: @nul_at_16
      ] do
    test "#{name}: stores as BLOB and reads back all 16 bytes" do
      id = unquote(Macro.escape(id))
      TestRepo.insert!(%Thing{id: id, label: "#{unquote(name)}"})

      assert typeof(id) == "blob",
             "stored as #{typeof(id)}; a binary id filed as text is invisible to a blob-typed lookup"

      assert stored_hex(id) == Base.encode16(id)

      reloaded = TestRepo.get!(Thing, id)

      assert reloaded.id == id,
             "id came back as #{byte_size(reloaded.id)} of #{byte_size(id)} bytes — " <>
               "truncated, almost certainly at a NUL"
    end
  end

  test "a :binary field is stored as BLOB too, not only the id" do
    id = Base.decode16!("11223344556677889900AABBCCDDEEFF")
    payload = @nul_at_5
    TestRepo.insert!(%Thing{id: id, payload: payload, label: "payload"})

    %{rows: [[t, h]]} =
      Ecto.Adapters.SQL.query!(TestRepo, "SELECT typeof(payload), hex(payload) FROM things WHERE id = ?1", [
        {:blob, id}
      ])

    assert t == "blob"
    assert h == Base.encode16(payload)
    assert TestRepo.get!(Thing, id).payload == payload
  end

  test "ordinary strings are still stored as TEXT" do
    # The regression this fix must not cause. In Elixir a string IS a binary,
    # so tagging indiscriminately — or reordering the checks inside the NIF —
    # would turn every text column into a BLOB.
    id = Base.decode16!("AABBCCDDEEFF00112233445566778899")
    TestRepo.insert!(%Thing{id: id, label: "an ordinary string"})

    %{rows: [[t]]} =
      Ecto.Adapters.SQL.query!(TestRepo, "SELECT typeof(label) FROM things WHERE id = ?1", [
        {:blob, id}
      ])

    assert t == "text"
    assert TestRepo.get!(Thing, id).label == "an ordinary string"
  end
end
