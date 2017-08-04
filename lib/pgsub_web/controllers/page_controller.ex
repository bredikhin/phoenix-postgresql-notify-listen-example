defmodule PgsubWeb.PageController do
  use PgsubWeb, :controller

  def index(conn, _params) do
    render conn, "index.html"
  end
end
