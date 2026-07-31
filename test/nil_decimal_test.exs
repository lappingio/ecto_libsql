defmodule EctoLibSql.NilDecimalTest do
  @moduledoc """
  A nullable `:decimal` column could not hold NULL: `decimal_encode/1` had no
  `nil` clause, so writing one raised

      (FunctionClauseError) no function clause matching in
      Ecto.Adapters.LibSql.decimal_encode/1

  Every sibling encoder — `bool_encode/1`, `datetime_encode/1`, `date_encode/1`,
  `time_encode/1`, `json_encode/1` — already handled `nil`; only decimal was
  missed.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule Priced do
    use Ecto.Schema

    schema "priced" do
      field(:label, :string)
      field(:amount, :decimal)
    end
  end

  @db "/tmp/ecto_libsql_nil_decimal_test.db"

  setup_all do
    File.rm(@db)
    {:ok, _} = TestRepo.start_link(database: @db)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS priced (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      label TEXT,
      amount DECIMAL
    )
    """)

    on_exit(fn -> File.rm(@db) end)
    :ok
  end

  test "a nil decimal round-trips" do
    TestRepo.insert!(%Priced{label: "unset", amount: nil})

    row = TestRepo.one!(from p in Priced, where: p.label == "unset")

    assert row.amount == nil
  end

  test "a present decimal still round-trips" do
    TestRepo.insert!(%Priced{label: "set", amount: Decimal.new("51.94")})

    row = TestRepo.one!(from p in Priced, where: p.label == "set")

    assert Decimal.equal?(row.amount, Decimal.new("51.94"))
  end

  test "nil and non-nil decimals coexist in one insert_all" do
    TestRepo.insert_all(Priced, [
      %{label: "bulk_nil", amount: nil},
      %{label: "bulk_set", amount: Decimal.new("1.23")}
    ])

    assert TestRepo.one!(from p in Priced, where: p.label == "bulk_nil").amount == nil
    assert TestRepo.one!(from p in Priced, where: p.label == "bulk_set").amount != nil
  end
end
