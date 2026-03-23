defmodule SeshatWeb.PageController do
  use SeshatWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
