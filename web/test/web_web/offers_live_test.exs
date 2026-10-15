defmodule WebWeb.OffersLiveTest do
  use WebWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders Buy tab by default and switches to Sell", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Buy CKB"
    html = view |> element("button[phx-value-tab=sell]") |> render_click()
    assert html =~ "Connect a wallet to create an offer"
    assert html =~ "My offers"
  end

  test "rejects an invalid phone number on create", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    render_click(view, "set_tab", %{"tab" => "sell"})
    html = render_hook(view, "create_offer", %{"identifier" => "0000000", "amount" => "100"})
    assert html =~ "valid Kenyan M-Pesa number"
  end
end
