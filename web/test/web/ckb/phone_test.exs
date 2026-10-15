defmodule Web.Ckb.PhoneTest do
  use ExUnit.Case, async: true
  alias Web.Ckb.Phone

  test "accepts the common Kenyan formats and normalizes them" do
    for input <- ["0712345678", "0712 345 678", "+254712345678", "254712345678", "712345678", "0112345678"] do
      assert {:ok, n} = Phone.normalize(input)
      assert String.starts_with?(n, "254") and byte_size(n) == 12
    end

    assert {:ok, "254712345678"} = Phone.normalize("+254 712-345-678")
  end

  test "rejects fakes and wrong shapes" do
    for input <- ["", "0000000", "0700000000", "0711111111", "071234567", "07123456789", "0212345678", "abc", "+255712345678"] do
      assert :error = Phone.normalize(input), "expected #{inspect(input)} to be rejected"
    end
  end

  test "display form" do
    assert Phone.display("254712345678") == "0712 345 678"
  end

  test "directory hash matches ckb.js SHA-256 convention" do
    assert Web.Ckb.OfferDirectory.hash("254712345678") ==
             "0x" <> Base.encode16(:crypto.hash(:sha256, "254712345678"), case: :lower)
  end
end
