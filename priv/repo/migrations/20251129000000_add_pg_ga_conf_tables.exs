defmodule PgGaConf.Repo.Migrations.AddPgGaConfTables do
  use Ecto.Migration

  def up, do: PgGaConf.Migrations.up()
  def down, do: PgGaConf.Migrations.down()
end
