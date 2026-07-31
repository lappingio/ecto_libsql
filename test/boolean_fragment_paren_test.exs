defmodule EctoLibSql.BooleanFragmentParenTest do
  @moduledoc """
  A fragment is arbitrary SQL and may be a bare subquery. When one is joined to
  another expression with AND/OR it has to be parenthesised, or the rendered SQL
  is `x AND SELECT ...`, which SQLite rejects with `near "SELECT": syntax error`.

  Found via Oban's `Oban.Engines.Lite`, whose `json_contains/2` macro is exactly
  such a fragment; its default args-based job uniqueness was unusable.
  ecto_sqlite3 parenthesises these operands via `op_to_binary/3`.
  """
  use ExUnit.Case, async: true

  import Ecto.Query

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule Job do
    use Ecto.Schema

    schema "jobs" do
      field(:args, :map)
      field(:state, :string)
    end
  end

  @test_db "/tmp/ecto_libsql_paren_test.db"

  setup_all do
    File.rm(@test_db)
    {:ok, _} = TestRepo.start_link(database: @test_db)
    on_exit(fn -> File.rm(@test_db) end)
    :ok
  end

  defp to_sql(query), do: :all |> Ecto.Adapters.SQL.to_sql(TestRepo, query) |> elem(0)

  defp subselect(field_expr) do
    dynamic(
      [j],
      fragment(
        "SELECT 0 NOT IN (SELECT json_extract(?, '$.k') FROM json_each(?) t)",
        ^%{"k" => 1},
        ^field_expr
      )
    )
  end

  test "AND-ing two bare-SELECT fragments parenthesises each operand" do
    query = from(j in Job) |> where(^dynamic(^subselect("a") and ^subselect("b")))

    sql = to_sql(query)

    refute sql =~ "AND SELECT", "operand was left bare, producing invalid SQL"
    assert sql =~ ") AND ("
  end

  test "OR-ing two bare-SELECT fragments parenthesises each operand" do
    query = from(j in Job) |> where(^dynamic(^subselect("a") or ^subselect("b")))

    sql = to_sql(query)

    refute sql =~ "OR SELECT"
    assert sql =~ ") OR ("
  end

  test "a fragment AND-ed with an ordinary comparison is still parenthesised" do
    comparison = dynamic([j], j.state == ^"available")
    query = from(j in Job) |> where(^dynamic(^subselect("a") and ^comparison))

    sql = to_sql(query)

    refute sql =~ "AND SELECT"
  end

  test "non-fragment operands are left unparenthesised, keeping SQL readable" do
    query = from(j in Job, where: j.state == ^"available" and j.id > ^1)

    assert to_sql(query) =~ ~s{(s0."state" = ?1 AND s0."id" > ?2)}
  end
end
