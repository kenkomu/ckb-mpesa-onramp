defmodule WebWeb.PageControllerTest do
  use WebWeb.ConnCase

  test "GET / renders the offers marketplace", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Open offers"
  end
end
