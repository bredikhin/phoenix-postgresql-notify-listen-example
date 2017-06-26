defmodule Pgsub.Web.PageController do
  use Pgsub.Web, :controller

  def index(conn, _params) do
    render conn, "index.html"
  end
end
